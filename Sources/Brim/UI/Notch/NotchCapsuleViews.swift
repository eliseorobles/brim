// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

// A floating capsule has no camera inside it, so what the closed island shows
// runs in one row from one round end to the other, and the capsule is as
// wide as that row. The service measures each row with NotchCapsuleLayout,
// and these views draw it with the same measures. A click anywhere on the
// capsule opens the island, on the activity's page when it shows one.

private typealias CapsuleLayout = NotchCapsuleLayout

/// One row between the capsule's round ends, centred in the menu bar.
private struct NotchCapsuleRow<Content: View>: View {
    let size: CGSize
    let geometry: NotchGeometry
    var leading = CapsuleLayout.endPadding
    var trailing = CapsuleLayout.endPadding
    @ViewBuilder let content: () -> Content

    var body: some View {
        let side = CapsuleLayout.side(geometry)
        content()
            .padding(.leading, side + leading)
            .padding(.trailing, side + trailing)
            .frame(width: size.width, height: geometry.stripHeight)
            .foregroundStyle(.white)
    }
}

private extension Text {
    func capsuleTitle() -> some View {
        font(Font(CapsuleLayout.titleFont as CTFont)).lineLimit(1)
    }

    func capsuleDetail() -> some View {
        font(Font(CapsuleLayout.detailFont as CTFont)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
    }
}

private struct NotchCapsuleSymbol: View {
    let name: String
    var tint: Color = .white

    var body: some View {
        Image(systemName: name)
            .font(.system(size: CapsuleLayout.symbolSize, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: CapsuleLayout.symbolWidth)
            .capsuleCentred(name)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// A symbol's ink, not its frame, meets the row's middle line, where the
    /// text beside it has its capitals.
    func capsuleCentred(_ symbol: String, size: CGFloat = CapsuleLayout.symbolSize,
                        weight: NSFont.Weight = .medium) -> some View {
        alignmentGuide(VerticalAlignment.center) {
            $0[VerticalAlignment.center] + CapsuleLayout.symbolDrop(symbol, size: size, weight: weight)
        }
    }
}

/// Feedback or a message, read from one end to the other.
struct NotchCapsuleNoticeView: View {
    let notice: NotchNotice
    let geometry: NotchGeometry
    let size: CGSize

    private var tint: Color {
        switch notice.event {
        // A warning reads as one in any agent's color; other AI notices wear it.
        case .agents: return notice.symbol.hasPrefix("exclamationmark") ? .orange : notice.agent?.tint ?? .white
        default: return .white
        }
    }

    var body: some View {
        NotchCapsuleRow(size: size, geometry: geometry) { messageRow }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notice.accessibilityText)
    }

    private var messageRow: some View {
        HStack(spacing: CapsuleLayout.spacing) {
            mark
            Text(notice.title).capsuleTitle().layoutPriority(1)
            if !notice.detail.isEmpty {
                Text(notice.detail).capsuleDetail()
                    .padding(.leading, CapsuleLayout.groupSpacing - CapsuleLayout.spacing)
            }
        }
    }

    @ViewBuilder private var mark: some View {
        // A notice about the agent itself wears its mark; warnings and
        // renewals keep a symbol that says what happened.
        if notice.event == .agents, let agent = notice.agent, notice.symbol == agent.symbol {
            NotchAgentMark(provider: agent, size: CapsuleLayout.symbolSize).frame(width: CapsuleLayout.symbolWidth)
        } else {
            NotchCapsuleSymbol(name: notice.symbol, tint: tint)
        }
    }
}

/// The closed capsule at rest: bare, or with the charge or the AI allowance
/// the person chose, in its middle.
struct NotchCapsuleRestingView: View {
    @ObservedObject var service: NotchService
    @AppStorage(DefaultsKey.notchLowBatteryTint) private var lowBatteryTint = false
    @AppStorage(DefaultsKey.notchLowBatteryThreshold) private var lowBatteryThreshold = NotchSupport.defaultLowBatteryThreshold
    @AppStorage(DefaultsKey.notchLowBatteryEarly) private var earlyBatteryWarning = false
    @AppStorage(DefaultsKey.notchLowBatteryEarlyThreshold) private var earlyBatteryThreshold = NotchSupport.defaultEarlyBatteryThreshold
    let size: CGSize
    /// Another display's capsule, when the island shows on every display.
    var displayGeometry: NotchGeometry? = nil

    private var geometry: NotchGeometry { displayGeometry ?? service.geometry }

    var body: some View {
        resting
            .accessibilityHidden(true)
    }

    private var resting: some View {
        NotchCapsuleRow(size: size, geometry: geometry) {
            HStack(spacing: 5) {
                switch service.idleContent {
                case .battery:
                    let symbol = NotchRestingBattery.symbol(for: service.power)
                    let tint = NotchRestingBattery.tint(for: service.power, tint: lowBatteryTint,
                                                        threshold: lowBatteryThreshold, early: earlyBatteryWarning,
                                                        earlyThreshold: earlyBatteryThreshold)
                    Image(systemName: symbol).font(.system(size: CapsuleLayout.symbolSize))
                        .capsuleCentred(symbol, weight: .regular)
                        .foregroundStyle(tint)
                    if let percent = service.power.chargePercent {
                        Text("\(percent)%").font(Font(CapsuleLayout.smallFont as CTFont)).lineLimit(1)
                            .foregroundStyle(tint)
                    }
                case .agents:
                    NotchAgentRestingWing(leading: true)
                    NotchAgentRestingWing(leading: false)
                case .none:
                    EmptyView()
                }
            }
            .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// The working agents' marks, side by side, each in a frame wider than it.
private struct NotchCapsuleAgentMarks: View {
    let providers: [AgentProvider]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(providers) { NotchAgentGlyph(provider: $0, size: CapsuleLayout.agentMarkSize(working: providers.count)) }
        }
    }
}

/// A working agent: its mark and the reading the person chose.
struct NotchCapsuleAgentStrip: View {
    @ObservedObject var service: NotchService
    let size: CGSize
    /// Another display's capsule, when the island shows on every display.
    var displayGeometry: NotchGeometry? = nil
    @ObservedObject private var usage = AgentUsageService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchAgentsReadout) private var readout = NotchAgentReadout.elapsed.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitDisplay) private var display = NotchAgentLimitDisplay.remaining.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitFocus) private var focus = NotchAgentLimitFocus.mostUsed.rawValue

    private func working(_ live: [AgentLiveSession]) -> [AgentProvider] {
        AgentProvider.allCases.filter { provider in live.contains { $0.provider == provider } }
    }

    var body: some View {
        // The last agent stopping empties the list before the strip has left.
        NotchStripHold(usage.snapshot.live, shows: !usage.snapshot.live.isEmpty) { row(live: $0) }
    }

    @ViewBuilder private func row(live: [AgentLiveSession]) -> some View {
        let working = working(live)
        NotchCapsuleRow(size: size, geometry: displayGeometry ?? service.geometry) {
            HStack(spacing: CapsuleLayout.spacing) {
                NotchCapsuleAgentMarks(providers: working)
                NotchAgentReadoutTimeline(readout: NotchAgentReadout(rawValue: readout) ?? .elapsed) { date in
                    let text = reading(at: date, live: live)
                    Text(text)
                        .font(Font(CapsuleLayout.readingFont as CTFont))
                        .foregroundStyle(working.first?.tint ?? .white)
                        .lineLimit(1).fixedSize()
                        // A reading that gains a digit, like an hour passing,
                        // widens the capsule; the service measures the same.
                        .onChange(of: NotchAgentSupport.readingShape(text)) { _, _ in
                            DispatchQueue.main.async { service.refreshPresentation() }
                        }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(working.map(\.displayName).joined(separator: ", "))
        .accessibilityValue(reading(at: Date(), live: live))
        .accessibilityHint(FeatureStrings.notch(l10n.language).open)
    }

    private func reading(at now: Date, live: [AgentLiveSession]) -> String {
        var snapshot = usage.snapshot
        snapshot.live = live
        return NotchAgentSupport.stripReading(snapshot, readout: NotchAgentReadout(rawValue: readout) ?? .elapsed,
                                              display: NotchAgentLimitDisplay(rawValue: display) ?? .remaining,
                                              focus: NotchAgentLimitFocus(rawValue: focus) ?? .mostUsed, now: now)
    }
}

/// A running Keep Awake session: the cup of its tile, then the time it has
/// left, or infinity for a session without an end. The reading changes once
/// a minute, so the clock wakes only then.
struct NotchCapsuleKeepAwakeStrip: View {
    @ObservedObject var service: NotchService
    let size: CGSize
    /// Another display's capsule, when the island shows on every display.
    var displayGeometry: NotchGeometry? = nil
    @ObservedObject private var awake = KeepAwakeManager.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        // Ending a session clears its end before the strip has left.
        NotchStripHold(awake.endDate, shows: awake.isActive) { content(end: $0) }
    }

    @ViewBuilder private func content(end: Date?) -> some View {
        if let end {
            TimelineView(.periodic(from: NotchKeepAwakeSupport.tickStart(until: end, now: Date()), by: 60)) { context in
                row(end: end, now: context.date)
            }
        } else {
            row(end: nil, now: Date())
        }
    }

    private func row(end: Date?, now: Date) -> some View {
        NotchCapsuleRow(size: size, geometry: displayGeometry ?? service.geometry) {
            HStack(spacing: CapsuleLayout.spacing) {
                // The cup is wider than the slot other marks share; the
                // capsule measures it as drawn.
                Image(systemName: NotchKeepAwakeSupport.symbol)
                    .font(.system(size: CapsuleLayout.symbolSize, weight: .medium))
                    .foregroundStyle(.yellow)
                    .capsuleCentred(NotchKeepAwakeSupport.symbol)
                if let end {
                    let text = NotchKeepAwakeSupport.compactText(until: end, now: now,
                                                                locale: Locale(identifier: l10n.language.rawValue))
                    Text(text)
                        .font(Font(CapsuleLayout.readingFont as CTFont))
                        .foregroundStyle(.yellow)
                        .lineLimit(1).fixedSize()
                        // A reading that gains or loses a character, like 10m
                        // becoming 9m, resizes the capsule; the service measures the same.
                        .onChange(of: NotchAgentSupport.readingShape(text)) { _, _ in
                            DispatchQueue.main.async { service.refreshPresentation() }
                        }
                } else {
                    Image(systemName: NotchKeepAwakeSupport.openSymbol)
                        .font(.system(size: CapsuleLayout.readingFont.pointSize, weight: .medium))
                        .foregroundStyle(.yellow)
                        .capsuleCentred(NotchKeepAwakeSupport.openSymbol, size: CapsuleLayout.readingFont.pointSize)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.localized(l10n.language).keepAwakeTitle)
        .accessibilityValue(NotchKeepAwakeStrip.status(end: end, language: l10n.language))
        .accessibilityHint(FeatureStrings.notch(l10n.language).open)
        .accessibilityIdentifier("notch.keepAwake")
    }
}
