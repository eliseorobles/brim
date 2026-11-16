// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Feedback keeps the central camera area clear on physical and simulated notches.
struct NotchNoticeView: View {
    let notice: NotchNotice
    let geometry: NotchGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var wings: NotchNoticeWings { notice.wings(in: geometry) }
    private var tint: Color {
        switch notice.event {
        // A warning reads as one in any agent's color; other AI notices wear it.
        case .agents: return notice.symbol.hasPrefix("exclamationmark") ? .orange : notice.agent?.tint ?? .white
        default: return .white
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .padding(.leading, notice.inset(wing: wings.leading))
                .padding(.trailing, notice.cameraGap)
                .frame(width: wings.leading, height: geometry.stripHeight)
                .clipped()
            Color.clear.frame(width: geometry.noticeCameraGap)
            trailing
                .padding(.trailing, notice.inset(wing: wings.trailing))
                .padding(.leading, notice.cameraGap)
                .frame(width: wings.trailing, height: geometry.stripHeight)
                .clipped()
        }
        .foregroundStyle(.white)
        .frame(height: geometry.stripHeight)
        // Each side is as wide as what it shows, so the island reaches
        // further toward the wider one and the camera's gap stays over it.
        .offset(x: (wings.trailing - wings.leading) / 2)
        // A new reading that needs another width moves its mark with the
        // island's steady ease, not ahead of it. Keyed on the notice's own
        // widths, so a display change does not ease it.
        .animation(reduceMotion ? nil : .spring(duration: NotchMotion.steadyWidth.duration, bounce: 0),
                   value: notice.preferredWings)
        .transaction { $0.disablesAnimations = false }
        // Another kind of notice is drawn anew at its place, as the island
        // springs to it, rather than easing out of the last one's layout.
        .id(notice.event)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.accessibilityText)
    }

    private var leading: some View {
        HStack(spacing: 8) {
            Group {
                // A notice about the agent itself wears its mark, and a
                // warning keeps a symbol that says what happened.
                if notice.event == .agents, let agent = notice.agent, notice.symbol == agent.symbol {
                    NotchAgentMark(provider: agent, size: 13)
                } else {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 18)
            Text(notice.title)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: notice.detail)
        .transaction { $0.disablesAnimations = false }
    }

    private var trailing: some View {
        Text(notice.detail)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
