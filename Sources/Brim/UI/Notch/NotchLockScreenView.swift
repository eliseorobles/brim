// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// What the lock screen may show, settled when it appears: preferences cannot
/// change while the Mac is locked, so the views never read them again.
final class NotchLockScreenModel: ObservableObject {
    @Published var showsAgents = false
    @Published var padlockOpen = false
}

/// The island at rest with a padlock beside the camera. The padlock closes
/// as the Mac locks and opens as it unlocks, before the island returns
/// underneath.
struct NotchLockScreenIsland: View {
    @ObservedObject var model: NotchLockScreenModel
    let size: CGSize
    let cameraWidth: CGFloat
    /// The window on whole points around the island, and the island's top
    /// left corner inside it; the rest of the window stays clear.
    var window: CGSize? = nil
    var origin: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let wing = max(0, (size.width - cameraWidth) / 2)
        NotchShape(attached: true, radius: NotchLayout.surfaceRadius(height: size.height))
            .fill(.black)
            .overlay {
                HStack(spacing: 0) {
                    Image(systemName: model.padlockOpen ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: min(13, size.height * 0.42), weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion ? false : model.padlockOpen)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.padlockOpen)
                        .frame(width: wing, height: size.height)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: size.width, height: size.height)
            .padding(.leading, origin.x)
            .padding(.top, origin.y)
            .frame(width: window?.width ?? size.width, height: window?.height ?? size.height, alignment: .topLeading)
            .accessibilityHidden(true)
    }
}

/// The working agents as one line under the clock, where a phone keeps the
/// widgets of its lock screen: their marks and a reading, with no card.
struct NotchLockScreenActivities: View {
    @ObservedObject var model: NotchLockScreenModel
    let size: CGSize
    @ObservedObject private var usage = AgentUsageService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchAgentsReadout) private var readout = NotchAgentReadout.elapsed.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitDisplay) private var display = NotchAgentLimitDisplay.remaining.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitFocus) private var focus = NotchAgentLimitFocus.mostUsed.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let shows = model.showsAgents && !usage.snapshot.live.isEmpty
            HStack {
                if shows {
                    agents(at: context.date)
                        .transition(.opacity)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .legibleOnWallpaper()
            .frame(width: size.width, height: size.height)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: shows)
        }
        .allowsHitTesting(false)
    }

    private func agents(at date: Date) -> some View {
        let working = AgentProvider.allCases.filter { provider in usage.snapshot.live.contains { $0.provider == provider } }
        let reading = NotchAgentSupport.stripReading(usage.snapshot, readout: NotchAgentReadout(rawValue: readout) ?? .elapsed,
                                                     display: NotchAgentLimitDisplay(rawValue: display) ?? .remaining,
                                                     focus: NotchAgentLimitFocus(rawValue: focus) ?? .mostUsed, now: date)
        // The agents and their reading only: a project's name stays off
        // a screen anyone can walk up to.
        return HStack(spacing: 7) {
            HStack(spacing: 1) {
                ForEach(working) { NotchAgentGlyph(provider: $0, size: 13) }
            }
            Text(working.map(\.displayName).joined(separator: " · ") + " " + reading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(working.map(\.displayName).joined(separator: ", ") + ", "
                            + FeatureStrings.notchLockScreen(l10n.language).working)
        .accessibilityValue(reading)
    }
}

private extension View {
    /// White type over any wallpaper, the way the lock screen's own clock
    /// stays readable over a bright photo.
    func legibleOnWallpaper() -> some View {
        shadow(color: .black.opacity(0.3), radius: 8, y: 1)
    }
}
