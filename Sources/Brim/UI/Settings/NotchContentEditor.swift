// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The open island for one section, hanging from a slice of menu bar: the
/// island's own pages at their real size, scaled into Settings, so every
/// option changes the preview the way it changes the island.
struct NotchIslandPreview: View {
    let module: NotchModule
    /// The section is switched off, or the feature behind it is.
    var hidden = false
    @ObservedObject private var notch = NotchService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchLiquidGlassEnabled) private var glass = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monitoring = false
    @State private var windowVisible = false
    private var editor: NotchEditorStrings { FeatureStrings.notchEditor(l10n.language) }
    private static let captionHeight: CGFloat = 28
    private static let margin: CGFloat = 16

    /// One scale for every section, taken from the tallest island, so the
    /// preview keeps its size and choosing a section never moves the list
    /// under the pointer.
    static func scale(in stage: CGSize) -> CGFloat {
        let largest = NotchService.shared.previewLargestSize
        guard largest.width > 0, largest.height > 0 else { return 1 }
        return max(0.1, min(1, (stage.width - margin * 2) / largest.width, (stage.height - captionHeight) / largest.height))
    }

    /// As tall as the tallest island at the scale that fits the width, within
    /// the limit the page gives it.
    static func height(width: CGFloat, limit: CGFloat) -> CGFloat {
        NotchService.shared.previewLargestSize.height * scale(in: CGSize(width: width, height: limit)) + captionHeight
    }

    var body: some View {
        previewSurface
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: module)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(editor.preview)
            .accessibilityValue(module.title(l10n.language) + (hidden ? ", " + editor.hiddenInIsland : ""))
            .onAppear { monitor(windowVisible && module == .system) }
            .onChange(of: module) { _, value in monitor(windowVisible && value == .system) }
            .onChange(of: windowVisible) { _, visible in monitor(visible && module == .system) }
            .onDisappear { monitor(false) }
    }

    private var previewSurface: some View {
        GeometryReader { proxy in stage(in: proxy.size) }
            .background(.quaternary.opacity(0.35))
            .background(WindowVisibilityReader { windowVisible = $0 })
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottomLeading) { caption }
    }

    private func stage(in stageSize: CGSize) -> some View {
        let geometry = notch.previewGeometry(for: module)
        let size = notch.previewSize(for: module)
        let scale = Self.scale(in: stageSize)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.06))
                .frame(height: geometry.menuBarHeight * scale)
            if windowVisible {
                island(size: size, geometry: geometry)
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .top)
                    .opacity(hidden ? 0.4 : 1)
            }
        }
        .frame(width: stageSize.width, height: stageSize.height, alignment: .top)
    }

    private var caption: some View {
        Label(hidden ? editor.hiddenInIsland : editor.preview, systemImage: hidden ? "eye.slash" : "eye")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    /// The system page reads live metrics, which sample only while a surface
    /// shows them; the preview counts as one, like the menu panel.
    private func monitor(_ wanted: Bool) {
        guard wanted != monitoring else { return }
        monitoring = wanted
        if wanted { SystemMonitor.shared.panelDidAppear() } else { SystemMonitor.shared.panelDidDisappear() }
    }

    private var glassSurface: Bool {
#if compiler(>=6.2)
        if #available(macOS 26, *) { return glass && !reduceTransparency }
#endif
        return false
    }

    /// The island as it opens on this section: the page, and its top row
    /// with what the page puts there, around the camera where the island has
    /// one. The row's own way to the sections leads it when nothing floats
    /// beside the island for that.
    private func island(size: CGSize, geometry: NotchGeometry) -> some View {
        let content = geometry.contentSize(for: size)
        let band = NotchBand(geometry: geometry, contentWidth: content.width)
        return NotchPagePreview(module: module, size: content)
            .frame(width: content.width, height: content.height, alignment: .top)
            .clipped()
            .padding(.top, geometry.pageTopInset - geometry.headerTopInset)
            .overlayPreferenceValue(NotchBandKey.self, alignment: .top) { items in
                if geometry.headerRowHeight > 0 {
                    NotchBandRow(band: band) {
                        if band.sectionsButton { NotchSectionsButton(action: {}) }
                        items.leading
                    } trailing: {
                        items.trailing
                    }
                }
            }
            .environment(\.notchBand, band)
            .padding(.horizontal, NotchLayout.horizontalInset)
            .padding(.top, geometry.headerTopInset)
            .padding(.bottom, NotchLayout.bottomInset)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background {
                NotchShape.island(height: size.height, geometry: geometry).fill(.black)
            }
            .foregroundStyle(.white)
            .tint(.white)
            .environment(\.colorScheme, .dark)
            .environment(\.notchPresentation, true)
            .environment(\.notchGlassSurface, glassSurface)
            .environment(\.notchSettingsPreview, true)
            .allowsHitTesting(false)
    }
}

/// A section's page as the island draws it.
struct NotchPagePreview: View {
    let module: NotchModule
    let size: CGSize
    @ObservedObject private var notch = NotchService.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        switch module {
        case .controls: NotchControlsView(service: notch, size: size)
        case .clipboard: NotchClipboardView(service: notch, size: size)
        case .system: NotchSystemView(size: size) { _ in }
        case .agents:
            // Off, nothing reads the logs, so the page would wait forever.
            if NotchAgentSupport.isEnabled() {
                NotchAgentsView(size: size)
            } else {
                NotchEmptyView(symbol: "sparkles", message: FeatureStrings.notchEditor(l10n.language).agentsSummary)
            }
        }
    }

}

/// One section in the list beside its options: the box that shows it in the
/// island, its icon and its name. A row drags to a new place; choosing one
/// opens its options and its preview. A box rather than a switch leaves the
/// name its whole line even in the narrowest window.
struct NotchSectionListRow: View {
    let module: NotchModule
    @Binding var included: Bool
    let available: Bool
    let selected: Bool
    @Binding var order: [NotchModule]
    @Binding var dragging: NotchModule?
    let select: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @State private var hovering = false
    private var editor: NotchEditorStrings { FeatureStrings.notchEditor(l10n.language) }
    private var title: String { module.title(l10n.language) }

    var body: some View {
        PanelReorderableItem(item: module, order: $order, dragging: $dragging) {
            HStack(spacing: 8) {
                // A section whose feature is off cannot show, whatever was chosen.
                Toggle(title, isOn: available ? $included : .constant(false))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!available)
                Button(action: select) {
                    HStack(spacing: 8) {
                        NotchSectionTile(module: module, shown: included && available, side: 22)
                        Text(title)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(available ? .primary : .secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 2)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(editor.summary(module))
                .accessibilityLabel(title)
                .accessibilityValue(editor.summary(module))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityAction(named: FeatureStrings.clipboard(l10n.language).moveUp) { move(by: -1) }
                .accessibilityAction(named: FeatureStrings.clipboard(l10n.language).moveDown) { move(by: 1) }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(selected ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(dragging == module ? 0.45 : 1)
        }
    }

    private func move(by offset: Int) {
        guard let index = order.firstIndex(of: module), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
    }
}

/// What the chosen section is, above its options: its icon, name and one
/// line on what it shows, and why it cannot show while its feature is off.
struct NotchSectionHeader: View {
    let module: NotchModule
    let shown: Bool
    /// Why an unavailable section cannot show.
    let reason: String?
    let openFeatures: () -> Void
    @ObservedObject private var l10n = L10n.shared
    private var editor: NotchEditorStrings { FeatureStrings.notchEditor(l10n.language) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NotchSectionTile(module: module, shown: shown, side: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title(l10n.language)).font(.title3.weight(.semibold))
                Text(editor.summary(module))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason {
                    HStack(spacing: 10) {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(editor.openFeatures, action: openFeatures).controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A section's icon on its own color; grey while the section is hidden.
struct NotchSectionTile: View {
    let module: NotchModule
    let shown: Bool
    let side: CGFloat

    var body: some View {
        Image(systemName: module.symbol)
            .font(.system(size: side * 0.46, weight: .semibold))
            .foregroundStyle(shown ? Color.white : Color.secondary)
            .frame(width: side, height: side)
            .background(shown ? module.settingsTint : Color.secondary.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: side * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension NotchModule {
    /// A color per section, like the icons of System Settings, so a long list
    /// can be scanned by eye.
    var settingsTint: Color {
        switch self {
        case .controls: return .blue
        case .clipboard: return .brown
        case .system: return .green
        case .agents: return Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }
}
