// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let menuPanelWillShow = Notification.Name("BrimMenuPanelWillShow")
}

struct MenuPanelFocusRequest: Equatable {
    let target: MenuPanelFocusTarget
    let serial: Int
}

enum MenuPanelFocusTarget: Equatable {
    case normal
    case section(PanelSectionID)
    case metric(MetricDetailKind)
}

final class MenuPanelFocus: ObservableObject {
    static let shared = MenuPanelFocus()

    @Published private(set) var request: MenuPanelFocusRequest?
    @Published private(set) var activeMetric: MetricDetailKind?
    @Published private(set) var isSwitchingMetricAnchor = false
    @Published private(set) var popoverIsVisible = false
    private var serial = 0

    private init() {}

    func showNormalPanel() {
        serial += 1
        activeMetric = nil
        request = MenuPanelFocusRequest(target: .normal, serial: serial)
    }

    func focus(_ section: PanelSectionID) {
        serial += 1
        activeMetric = nil
        request = MenuPanelFocusRequest(target: .section(section), serial: serial)
    }

    func focus(_ metric: MetricDetailKind) {
        serial += 1
        activeMetric = metric
        request = MenuPanelFocusRequest(target: .metric(metric), serial: serial)
    }

    func clearMetricFocus() {
        activeMetric = nil
    }

    func setSwitchingMetricAnchor(_ switching: Bool) {
        isSwitchingMetricAnchor = switching
    }

    func setPopoverVisible(_ visible: Bool) {
        guard popoverIsVisible != visible else { return }
        popoverIsVisible = visible
    }
}

/// Content of the menu bar popover: keep-awake controls, the system monitor,
/// the utilities and the other installed features' sections.
struct MenuPanelView: View {
    var notchSize: CGSize? = nil
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var panelFocus = MenuPanelFocus.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(DefaultsKey.monitorShowSystem) private var showSystem = true
    @AppStorage(DefaultsKey.monitorShowNetwork) private var showNetwork = true
    @AppStorage(DefaultsKey.monitorShowDisk) private var showDisk = true
    @AppStorage(DefaultsKey.monitorShowPower) private var showPower = true
    @AppStorage(DefaultsKey.panelShowFanControl) private var showFanControl = true
    @AppStorage(DefaultsKey.panelShowKeepAwake) private var showKeepAwake = true
    @AppStorage(DefaultsKey.panelShowUtilities) private var showUtilities = true
    @AppStorage(DefaultsKey.panelShowControls) private var showControls = true
    @AppStorage(DefaultsKey.panelShowClaude) private var showClaude = true
    @AppStorage(DefaultsKey.panelShowMemory) private var showMemory = true
    @AppStorage(DefaultsKey.panelSectionOrder) private var sectionOrderRaw = ""
    @State private var navigableContentHeight: CGFloat = 0
    @State private var metricContentHeight: CGFloat = 0
    @State private var selectedSection: PanelSectionID = PanelLayout.order.first ?? .keepAwake
    @State private var selectedMetric: MetricDetailKind?
    @FocusState private var focusedSection: PanelSectionID?

    /// Cap the panel to the usable screen height so it never overflows the menu
    /// bar; taller content scrolls inside. Measured against the display the
    /// menu bar icon is on, which is not always the one holding the key window.
    /// The popover's window is the panel plus 13 pt for the arrow and 13 pt
    /// below it, and a window taller than the usable height makes AppKit open
    /// the popover beside the icon instead of under it. The cap leaves those
    /// 26 pt and 2 more.
    private var maxHeight: CGFloat {
        let anchored = PanelInteractionState.shared.anchorScreen
            .flatMap { anchor in anchor.isStillAttached ? anchor : nil }
        return max(360, ((anchored ?? NSScreen.withMenuBar)?.visibleFrame.height ?? 760) - 28)
    }

    var body: some View {
        Group {
            if let notchSize {
                embeddedPanel(size: notchSize)
            } else if selectedMetric != nil {
                metricPanel
            } else {
                navigablePanel
            }
        }
        .onAppear {
            applyFocus(panelFocus.request)
            KeepAwakeManager.shared.refreshPasswordlessStatus()
            syncMonitorSampling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuPanelWillShow)) { _ in
            syncMonitorSampling()
        }
        .onDisappear {
            if !panelFocus.isSwitchingMetricAnchor {
                SystemMonitor.shared.setMenuPanelNeeds(.none)
            }
        }
        .onChange(of: monitorNeeds) { _, _ in
            syncMonitorSampling()
        }
        .onChange(of: panelFocus.request) { _, request in
            applyFocus(request)
        }
        .onChange(of: focusedSection) { _, section in
            if let section { selectedSection = section }
        }
    }

    private var monitorNeeds: SystemMonitorPanelNeeds {
        if let selectedMetric {
            return selectedMetric.monitorNeeds
        }
        switch activeSection {
        case .system: return SystemMonitorPanelNeeds(system: true)
        case .network: return SystemMonitorPanelNeeds(network: true)
        case .disk: return SystemMonitorPanelNeeds(disk: true)
        case .power: return SystemMonitorPanelNeeds(power: true, powerCard: true)
        default: return .none
        }
    }

    private func syncMonitorSampling() {
        SystemMonitor.shared.setMenuPanelNeeds(monitorNeeds)
    }

    private func applyFocus(_ request: MenuPanelFocusRequest?) {
        guard let request else { return }
        switch request.target {
        case .normal:
            selectedMetric = nil
        case .section(let section):
            guard isSectionVisible(section) else { return }
            selectedMetric = nil
            selectedSection = section
            focusedSection = section
        case .metric(let metric):
            focusedSection = nil
            selectedMetric = metric
            selectedSection = metric.panelSection
        }
    }

    /// Uses the same sections and actions inside an existing surface. The
    /// host already supplies the title and material; one native scroll view
    /// keeps long sections usable without nesting two scroll regions.
    private func embeddedPanel(size: CGSize) -> some View {
        VStack(spacing: 12) {
            Group {
                if let selectedMetric { metricNavigationHeader(selectedMetric) }
                else { sectionNavigation }
            }
            .frame(height: 38)
            OverlayScrollView(measuredHeight: $navigableContentHeight) {
                Group {
                    if let selectedMetric { MetricDetailView(kind: selectedMetric) }
                    else { section(for: activeSection, collapsible: false) }
                }
                .frame(width: size.width)
                .environment(\.notchPresentation, true)
                .environment(\.colorScheme, .dark)
            }
            .frame(width: size.width, height: max(0, size.height - 96))
            footer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var navigablePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sectionNavigation

            OverlayScrollView(measuredHeight: $navigableContentHeight) {
                VStack(alignment: .leading, spacing: 12) {
                    section(for: activeSection, collapsible: false)
                }
                .frame(width: 308)
            }
            .frame(width: 308, height: navigableScrollHeight)

            footer
        }
        .padding(12)
        .frame(width: 332, height: navigablePanelHeight)
        .panelGlassSurface()
    }

    private var metricPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let selectedMetric {
                metricNavigationHeader(selectedMetric)
                OverlayScrollView(measuredHeight: $metricContentHeight) {
                    MetricDetailView(kind: selectedMetric)
                        .frame(width: 308)
                }
                .frame(width: 308, height: metricScrollHeight)
            }

            footer
        }
        .padding(12)
        .frame(width: 332, height: metricPanelHeight)
        .panelGlassSurface()
    }

    /// The major sections in the user's saved order. Reading `sectionOrderRaw`
    /// (the @AppStorage backing) establishes the dependency so reordering in
    /// Settings refreshes the live panel; PanelLayout fills in any sections the
    /// saved order omits.
    private var orderedSections: [PanelSectionID] {
        _ = sectionOrderRaw
        return PanelLayout.order
    }

    private var visibleSections: [PanelSectionID] {
        orderedSections.filter(isSectionVisible)
    }

    private var activeSection: PanelSectionID {
        visibleSections.contains(selectedSection) ? selectedSection : (visibleSections.first ?? .keepAwake)
    }

    private var navigableScrollHeight: CGFloat {
        let measured = navigableContentHeight == 0 ? estimatedNavigableContentHeight : navigableContentHeight
        return min(measured, max(80, maxHeight - navigableChromeHeight))
    }

    private var navigablePanelHeight: CGFloat {
        min(maxHeight, max(220, navigableScrollHeight + navigableChromeHeight))
    }

    private var metricScrollHeight: CGFloat {
        let measured = metricContentHeight == 0 ? estimatedMetricContentHeight : metricContentHeight
        return min(measured, max(80, maxHeight - navigableChromeHeight))
    }

    private var metricPanelHeight: CGFloat {
        min(maxHeight, max(220, metricScrollHeight + navigableChromeHeight))
    }

    private var navigableChromeHeight: CGFloat { 180 }

    private var estimatedNavigableContentHeight: CGFloat {
        switch activeSection {
        case .keepAwake: return 250
        case .system: return 460
        case .network: return 190
        case .disk: return 360
        case .power: return 170
        case .fanControl: return 220
        case .utilities: return 500
        case .controls: return 120
        case .memory: return 420
        case .claude: return 330
        }
    }

    private var estimatedMetricContentHeight: CGFloat {
        guard let selectedMetric else { return 320 }
        switch selectedMetric {
        case .cpu, .gpu, .memory: return 430
        case .network: return 330
        case .disk: return 360
        case .battery, .power: return 360
        case .fan, .connectedDevices: return 240
        }
    }

    /// Renders the section for an id, honoring its "show in panel" toggle. Each
    /// section self-hides when it has nothing to show, so the order is stable
    /// whether or not a section is currently populated.
    @ViewBuilder
    private func section(for id: PanelSectionID, collapsible: Bool = true) -> some View {
        switch id {
        case .keepAwake: KeepAwakeCard(collapsible: collapsible)
        case .system:
            if showSystem {
                SystemSection(collapsible: collapsible) {
                    focusedSection = nil
                    selectedMetric = .connectedDevices
                }
            }
        case .network: if showNetwork { NetworkSection(collapsible: collapsible) }
        case .disk: if showDisk { DiskSection(collapsible: collapsible) }
        case .power: if showPower { PowerSection(collapsible: collapsible) }
        case .fanControl:
            // The popover retains its host after closing; detach the curve editor
            // so cooling heartbeats cannot keep laying out an unseen panel.
            if showFanControl, notchSize != nil || panelFocus.popoverIsVisible {
                FanControlSection(collapsible: collapsible)
            }
        case .utilities: UtilitiesSection(collapsible: collapsible)
        case .controls: QuickControlsSection(collapsible: collapsible)
        case .memory: if showMemory { MemoryPanelSection(collapsible: collapsible) }
        case .claude: if showClaude { ClaudeAccountsPanelSection(collapsible: collapsible) }
        }
    }

    /// The rule lives in PanelLayout; reading the @AppStorage values here is
    /// what keeps the tabs refreshing when Settings flips one of them.
    private func isSectionVisible(_ id: PanelSectionID) -> Bool {
        _ = (showKeepAwake, showSystem, showNetwork,
             showDisk, showPower, showFanControl, showUtilities, showControls, showClaude, showMemory)
        return PanelLayout.isVisibleInPanel(id)
    }

    private var sectionNavigation: some View {
        HStack(spacing: 2) {
            ForEach(visibleSections) { id in
                let isActive = activeSection == id
                Button {
                    selectedSection = id
                    focusedSection = id
                } label: {
                    Image(systemName: id.symbolName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .focused($focusedSection, equals: id)
                .foregroundStyle(isActive ? (notchSize != nil ? Color.white : Color.accentColor) : Color.secondary.opacity(0.86))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? navigationActiveFill : Color.clear)
                )
                .help(id.title(l10n.s))
                // Icon-only tabs: VoiceOver reads the section name, not the
                // symbol's, and hears which one is showing.
                .accessibilityLabel(id.title(l10n.s))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(notchSize != nil ? .black : PanelSurface.cardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PanelSurface.border(for: colorScheme), lineWidth: 0.7)
        )
    }

    private var navigationActiveFill: Color {
        if notchSize != nil { return .black }
        return colorScheme == .light ? Color.accentColor.opacity(0.13) : Color.accentColor.opacity(0.20)
    }

    private func metricNavigationHeader(_ kind: MetricDetailKind) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedMetric = nil
                selectedSection = kind.panelSection
                MenuPanelFocus.shared.clearMetricFocus()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(PanelSurface.cardFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(PanelSurface.border(for: colorScheme), lineWidth: 0.7)
            )

            Label(kind.title(l10n.s), systemImage: kind.symbolName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        MenuPanelHeader()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerButton(l10n.s.panelSettings,
                         systemImage: "gearshape",
                         horizontalPadding: 7) {
                // The hosted utility's own page, or the general one from the
                // panel's lists: the router is sticky, so it is set every time.
                SettingsRouter.shared.page = PanelInteractionState.shared.hostedSettingsPage ?? .general
                appDelegate()?.openSettingsWindow()
            }

            footerButton(l10n.s.panelQuit,
                         systemImage: "power",
                         horizontalPadding: 7) {
                NSApp.terminate(nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .padding(.top, 4)
    }

    private func footerButton(_ title: String, systemImage: String,
                              horizontalPadding: CGFloat = 8,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.78)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(notchSize != nil ? .black : PanelSurface.cardFill(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(PanelSurface.border(for: colorScheme), lineWidth: 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct MenuPanelHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ZStack {
            BrandMark(width: 48, tint: markTint)
                .frame(height: 28)
                .accessibilityHidden(true)

            if AppInfo.isBeta {
                HStack {
                    Text(l10n.s.betaBadgeLabel.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())

                    Spacer()
                }
            }
        }
        .frame(height: 28)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private var markTint: Color {
        colorScheme == .light ? Color(white: 0.03) : .white
    }
}

private enum UtilityPanelItem: String, PanelOrderItem, Identifiable {
    // Case order IS the default panel order (PanelLayout.itemOrder falls back
    // to allCases).
    case appUpdates, cleaner, homebrew, clipboard, uninstaller, portManager

    var id: String { rawValue }

    /// The hub feature behind the tile; off in the hub removes it everywhere,
    /// including the edit and hidden lists.
    var feature: AppFeature {
        switch self {
        case .cleaner: return .cleaner
        case .homebrew: return .homebrew
        case .appUpdates: return .appUpdates
        case .clipboard: return .clipboardHistory
        case .uninstaller: return .uninstaller
        case .portManager: return .portManager
        }
    }
}

struct UtilitiesSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @State private var showUninstaller = false
    @State private var showCleanerPanel = false
    @State private var showHomebrewPanel = false
    @State private var showAppUpdatesPanel = false
    @State private var showClipboardPanel = false
    @State private var showPortManagerPanel = false
    @AppStorage(DefaultsKey.panelUtilityUninstaller) private var showUninstallerAction = true
    @AppStorage(DefaultsKey.panelUtilityCleaner) private var showCleanerAction = true
    @AppStorage(DefaultsKey.panelUtilityHomebrew) private var showHomebrew = true
    @AppStorage(DefaultsKey.panelUtilityAppUpdates) private var showAppUpdates = true
    @AppStorage(DefaultsKey.panelUtilityClipboard) private var showClipboard = true
    @AppStorage(DefaultsKey.panelUtilityPortManager) private var showPortManager = true
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var clipboardEnabled = false
    @AppStorage(DefaultsKey.panelUtilityOrder) private var utilityOrderRaw = ""
    @State private var draggingItem: UtilityPanelItem?
    var collapsible = true

    var body: some View {
        PanelSection(.utilities, title: l10n.s.utilitiesSection, collapsible: collapsible,
                     supportsEditing: true,
                     editButtonVisible: !isHostingUtility,
                     resetAction: resetPanelDefaults) { editing in
            if showUninstaller {
                PanelUninstallerView {
                    showUninstaller = false
                }
            } else if showCleanerPanel {
                PanelCleanerView {
                    showCleanerPanel = false
                }
            } else if showHomebrewPanel {
                PanelHomebrewView {
                    showHomebrewPanel = false
                }
            } else if showClipboardPanel {
                PanelClipboardView {
                    PanelInteractionState.shared.viewKeepsPopoverOpen = false
                    showClipboardPanel = false
                }
            } else if showAppUpdatesPanel {
                PanelAppUpdatesView {
                    PanelInteractionState.shared.viewKeepsPopoverOpen = false
                    showAppUpdatesPanel = false
                }
            } else if showPortManagerPanel {
                PanelPortManagerView {
                    PanelInteractionState.shared.viewKeepsPopoverOpen = false
                    showPortManagerPanel = false
                }
            } else {
                PanelRowGroup(items: items(editing: editing), showsDragHandles: editing) { item in
                    PanelReorderableItem(item: item,
                                         isEnabled: editing,
                                         previewsAsCard: true,
                                         order: itemOrderBinding,
                                         dragging: $draggingItem) {
                        itemView(item, editing: editing)
                    }
                }
            }
        }
        .onChange(of: hostedUtilityKeepsPopoverOpen) { _, keepsOpen in
            PanelInteractionState.shared.viewKeepsPopoverOpen = keepsOpen
        }
        .onChange(of: hostedSettingsPage) { _, page in
            PanelInteractionState.shared.hostedSettingsPage = page
        }
        .onDisappear {
            // Another section, or a metric, replacing this one takes the
            // tool off screen with it; a closed panel does not, and keeps it.
            PanelInteractionState.shared.viewKeepsPopoverOpen = false
            PanelInteractionState.shared.hostedSettingsPage = nil
        }
    }

    /// The Settings page that belongs to whichever tool the section is
    /// showing, derived from the same state as `isHostingUtility` so every
    /// hosted tool is covered by the one list. Mirrored by the `onChange`
    /// beside it, and cleared only where this section leaves the screen.
    private var hostedSettingsPage: SettingsPage? {
        if showUninstaller { return .uninstaller }
        if showCleanerPanel { return .cleaner }
        if showHomebrewPanel { return .homebrew }
        if showClipboardPanel { return .clipboard }
        if showAppUpdatesPanel { return .appUpdates }
        if showPortManagerPanel { return .portManager }
        return nil
    }

    /// True while the section is showing one of the tools instead of its own
    /// list. A hosted tool turns the panel into a work surface, so clicks
    /// elsewhere in the app must not dismiss it.
    private var isHostingUtility: Bool {
        showUninstaller || showCleanerPanel || showHomebrewPanel
            || showClipboardPanel || showAppUpdatesPanel || showPortManagerPanel
    }

    /// Homebrew browsing behaves like an ordinary popover. Other hosted tools
    /// intentionally span interaction with apps and windows outside the panel.
    private var hostedUtilityKeepsPopoverOpen: Bool {
        isHostingUtility && !showHomebrewPanel
    }

    private var orderedItems: [UtilityPanelItem] {
        _ = utilityOrderRaw
        return PanelLayout.itemOrder(UtilityPanelItem.self, key: DefaultsKey.panelUtilityOrder)
    }

    private var itemOrderBinding: Binding<[UtilityPanelItem]> {
        Binding {
            orderedItems
        } set: { newValue in
            PanelLayout.setItemOrder(newValue, key: DefaultsKey.panelUtilityOrder)
        }
    }

    private func items(editing: Bool) -> [UtilityPanelItem] {
        orderedItems.filter { $0.feature.isAvailable && (editing || isVisible($0)) }
    }

    private func isVisible(_ item: UtilityPanelItem) -> Bool {
        switch item {
        case .homebrew: return showHomebrew
        case .appUpdates: return showAppUpdates
        case .clipboard: return showClipboard
        case .uninstaller: return showUninstallerAction
        case .cleaner: return showCleanerAction
        case .portManager: return showPortManager
        }
    }

    @ViewBuilder
    private func itemView(_ item: UtilityPanelItem, editing: Bool) -> some View {
        switch item {
        case .homebrew:
            UtilityActionButton(title: l10n.s.homebrewName,
                                caption: l10n.s.homebrewEnableCaption,
                                systemImage: "shippingbox",
                                isEditing: editing,
                                visibility: $showHomebrew,
                                action: {
                                    showHomebrewPanel = true
                                })
        case .appUpdates:
            UtilityActionButton(title: FeatureStrings.appUpdates(l10n.language).pageTitle,
                                caption: FeatureStrings.appUpdates(l10n.language).panelCaption,
                                systemImage: "arrow.down.app",
                                isEditing: editing,
                                visibility: $showAppUpdates,
                                action: {
                                    showAppUpdatesPanel = true
                                })
        case .clipboard:
            UtilityActionButton(title: FeatureStrings.clipboard(l10n.language).title,
                                caption: clipboardEnabled
                                    ? FeatureStrings.clipboard(l10n.language).caption
                                    : FeatureStrings.clipboard(l10n.language).disabled,
                                systemImage: "doc.on.clipboard",
                                isEditing: editing,
                                visibility: $showClipboard,
                                captionStaysVisible: !clipboardEnabled,
                                shortcutHint: shortcutHint(.clipboard),
                                action: {
                                    showClipboardPanel = true
                                })
        case .uninstaller:
            UtilityActionButton(title: l10n.s.uninstallerName,
                                caption: l10n.s.uninstallerEnableCaption,
                                systemImage: "trash",
                                isEditing: editing,
                                visibility: $showUninstallerAction,
                                action: {
                                    showUninstaller = true
                                })
        case .cleaner:
            UtilityActionButton(title: l10n.s.cleanerName,
                                caption: l10n.s.cleanerPanelCaption,
                                systemImage: "sparkle",
                                isEditing: editing,
                                visibility: $showCleanerAction,
                                action: {
                                    showCleanerPanel = true
                                })
        case .portManager:
            UtilityActionButton(title: FeatureStrings.portManager(l10n.language).title,
                                caption: FeatureStrings.portManager(l10n.language).listeningCaption,
                                systemImage: "network",
                                isEditing: editing,
                                visibility: $showPortManager,
                                action: { showPortManagerPanel = true })
        }
    }

    /// The row's key hint: only when the shortcut is actually REGISTERED,
    /// using the same gates the services use (the clipboard needs both the
    /// feature and its shortcut toggle), so the badge never advertises a
    /// combo that does nothing.
    private func shortcutHint(_ role: GlobalShortcutRole) -> String? {
        guard role.feature.isAvailable,
              role.requiredEnableKeys.allSatisfy({ UserDefaults.standard.bool(forKey: $0) })
        else { return nil }
        return role.assignedShortcut()?.displayString
    }

    private func resetPanelDefaults() {
        PanelLayout.resetItemOrder(key: DefaultsKey.panelUtilityOrder)
        utilityOrderRaw = ""
        showHomebrew = true
        showAppUpdates = true
        showClipboard = true
        showUninstallerAction = true
        showCleanerAction = true
        showPortManager = true
    }
}

/// The panel's quick control: the island switched on or off, as on its
/// Settings page. Edit mode hides or shows the row.
struct QuickControlsSection: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchEnabled) private var notchEnabled = false
    @AppStorage(DefaultsKey.panelControlNotch) private var showNotch = true
    var collapsible = true

    var body: some View {
        PanelSection(.controls, title: l10n.s.quickControlsSection, collapsible: collapsible,
                     supportsEditing: true,
                     resetAction: { showNotch = true }) { editing in
            PanelRowGroup(items: editing || showNotch ? [AppFeature.notch] : []) { _ in
                notchRow(editing: editing)
            }
        }
    }

    private func notchRow(editing: Bool) -> some View {
        let text = FeatureStrings.notch(l10n.language)
        return PanelToggleRow(title: text.title,
                              caption: text.description,
                              systemImage: "macbook",
                              isOn: $notchEnabled,
                              isEditing: editing,
                              visibility: $showNotch,
                              accessoryTitle: l10n.s.menuSettings,
                              accessoryAction: {
                                  SettingsRouter.shared.page = .notch
                                  appDelegate()?.openSettingsWindow()
                              })
            .onChange(of: notchEnabled) { _, _ in
                NotchService.shared.syncWithPreferences()
            }
    }
}

/// An action row of the Utilities section.
struct UtilityActionButton: View {
    let title: String
    let caption: String
    let systemImage: String
    var isEditing = false
    var visibility: Binding<Bool>? = nil
    /// The caption reports a state the tool is in, such as the clipboard
    /// history being off, so it stays on the row. Any other caption only
    /// describes the tool.
    var captionStaysVisible = false
    /// The feature's enabled global shortcut, shown as a quiet key hint so
    /// the panel row doubles as a reminder that the keyboard path exists.
    var shortcutHint: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if isEditing {
                rowContent(showChevron: false)
                    .panelRowInsets()
            } else {
                Button(action: action) {
                    rowContent(showChevron: true)
                        .panelRowInsets()
                        .background(PanelRowHighlight(isVisible: hovering))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
        }
        .panelRowDescription(showsCaption ? nil : caption)
    }

    /// The panel is where tools are used, and the Features page and Settings
    /// explain them. A plain description waits in the tooltip and the
    /// VoiceOver help, so the list stays one line per tool. It comes back in
    /// edit mode, where deciding what to keep is the whole point.
    private var showsCaption: Bool {
        captionStaysVisible || isEditing
    }

    private func rowContent(showChevron: Bool) -> some View {
        HStack(spacing: PanelRowMetrics.iconSpacing) {
            if isEditing {
                PanelDragHandle()
            }
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: PanelRowMetrics.iconWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHiddenInEditor ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showsCaption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(captionColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if isEditing, let visibility {
                if !visibility.wrappedValue {
                    PanelHiddenBadge()
                }
                PanelInlineHideButton(isVisible: visibility)
            } else {
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var iconColor: Color {
        isHiddenInEditor ? .secondary : .accentColor
    }

    private var captionColor: Color {
        isHiddenInEditor ? Color.secondary.opacity(0.55) : .secondary
    }

    private var isHiddenInEditor: Bool {
        isEditing && visibility?.wrappedValue == false
    }
}

/// The switch row of the Controls section.
struct PanelToggleRow: View {
    let title: String
    let caption: String
    let systemImage: String
    @Binding var isOn: Bool
    var isEditing = false
    var visibility: Binding<Bool>? = nil
    /// Optional inline action under the title, shown only outside edit mode.
    var accessoryTitle: String? = nil
    var accessoryAction: (() -> Void)? = nil

    var body: some View {
        rowContent
            .panelRowInsets()
            .panelRowDescription(showsCaption ? nil : caption)
    }

    /// Edit mode spells out every description. Otherwise what the switch
    /// does is the tooltip, like on every other panel row.
    private var showsCaption: Bool { isEditing }

    private var rowContent: some View {
        HStack(spacing: PanelRowMetrics.iconSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: PanelRowMetrics.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHiddenInEditor ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showsCaption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(captionColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isEditing, let accessoryTitle, let accessoryAction {
                    Button {
                        accessoryAction()
                    } label: {
                        Label(accessoryTitle, systemImage: "arrow.up.forward.square")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isEditing, let visibility {
            if !visibility.wrappedValue {
                PanelHiddenBadge()
            }
            PanelInlineHideButton(isVisible: visibility)
        } else {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .controlSize(.small)
                .toggleStyle(.switch)
                .accessibilityHint(showsCaption ? "" : caption)
        }
    }

    private var iconColor: Color {
        if isHiddenInEditor { return .secondary }
        return isOn ? .accentColor : .secondary
    }

    private var captionColor: Color {
        isHiddenInEditor ? Color.secondary.opacity(0.55) : .secondary
    }

    private var isHiddenInEditor: Bool {
        isEditing && visibility?.wrappedValue == false
    }
}

// MARK: - Grouped rows

/// Spacing shared by the rows inside a `PanelRowGroup`. The insets match
/// the padding of the other panel cards, so a row's text lines up with
/// them, and separators start under the titles rather than the icons.
enum PanelRowMetrics {
    static let iconWidth: CGFloat = 22
    static let iconSpacing: CGFloat = 9
    static let dragHandleWidth: CGFloat = 16

    static func horizontalInset(island: Bool) -> CGFloat { island ? 12 : 10 }

    static func verticalInset(island: Bool) -> CGFloat { island ? 10 : 8 }

    static func separatorInset(island: Bool) -> CGFloat {
        horizontalInset(island: island) + iconWidth + iconSpacing
    }
}

/// One card for a list of panel rows, split by hairlines: a long list reads
/// as one block instead of a stack of separate boxes, and every row stays its
/// own target.
struct PanelRowGroup<Item: Hashable, Row: View>: View {
    let items: [Item]
    /// Edit mode puts a drag handle before every icon, so the separators
    /// move over with the titles.
    var showsDragHandles = false
    @ViewBuilder let row: (Item) -> Row
    @Environment(\.notchPresentation) private var notchPresentation

    var body: some View {
        if !items.isEmpty {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Divider()
                        .padding(.leading, PanelRowMetrics.separatorInset(island: notchPresentation)
                                    + (showsDragHandles ? PanelRowMetrics.dragHandleWidth + PanelRowMetrics.iconSpacing : 0))
                        .padding(.trailing, PanelRowMetrics.horizontalInset(island: notchPresentation))
                        .accessibilityHidden(true)
                }
                row(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(interactive: false, padded: false)
    }
}

/// The hover fill of a tappable row, inset from the group's edges so it
/// never crosses the rounded corners of the card around it.
struct PanelRowHighlight: View {
    let isVisible: Bool
    @Environment(\.notchPresentation) private var notchPresentation

    var body: some View {
        RoundedRectangle(cornerRadius: notchPresentation ? 14 : 7, style: .continuous)
            .fill((notchPresentation ? Color.white : Color.primary)
                .opacity(isVisible ? (notchPresentation ? 0.08 : 0.06) : 0))
            .padding(notchPresentation ? 4 : 3)
    }
}

private struct PanelRowInsets: ViewModifier {
    @Environment(\.notchPresentation) private var notchPresentation

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PanelRowMetrics.horizontalInset(island: notchPresentation))
            .padding(.vertical, PanelRowMetrics.verticalInset(island: notchPresentation))
    }
}

extension View {
    /// The padding a row gets inside a `PanelRowGroup`.
    func panelRowInsets() -> some View {
        modifier(PanelRowInsets())
    }

    /// A row's description as its tooltip, and through it the VoiceOver
    /// help, whenever the row does not print it. An empty help keeps the
    /// row one view while its caption comes and goes, so a switch that turns
    /// on into a permission note is not rebuilt mid-animation.
    func panelRowDescription(_ description: String?) -> some View {
        help(description ?? "")
    }
}

// MARK: - Overlay scroll container

/// A vertical scroll container that always uses an overlay scroller, so it never
/// reserves a legacy gutter on the right (which, when the system is set to always
/// show scroll bars, would push the fixed-width panel content off-center). The
/// content is pinned to the full width and reports its natural height back after
/// every layout pass, so the popover sizes itself to fit and only scrolls once the
/// content is taller than the screen.
private struct OverlayScrollView<Content: View>: NSViewRepresentable {
    @Binding var measuredHeight: CGFloat
    let content: Content

    init(measuredHeight: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        _measuredHeight = measuredHeight
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let host = HeightReportingHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: clip.topAnchor),
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            host.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        context.coordinator.host = host
        installReporter(on: host)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.scrollerStyle = .overlay
        guard let host = context.coordinator.host else { return }
        host.rootView = content
        installReporter(on: host)               // re-bind to the latest measuredHeight
        let h = host.fittingSize.height          // catch content changes with no new layout pass
        if h > 1, abs(h - measuredHeight) > 0.5 {
            DispatchQueue.main.async { measuredHeight = h }
        }
    }

    /// Wire the hosting view to report its natural height into `measuredHeight`
    /// after every AppKit layout pass — including the frames of a collapse/expand
    /// animation — so the popover tracks the real content height instead of a
    /// single stale reading taken when SwiftUI happened to re-run updateNSView.
    /// The 0.5pt guard also breaks the measure → resize → measure feedback loop.
    private func installReporter(on host: HeightReportingHostingView<Content>) {
        let binding = $measuredHeight
        host.onLayout = { [weak host] in
            guard let host else { return }
            let h = host.fittingSize.height
            guard h > 1, abs(h - binding.wrappedValue) > 0.5 else { return }
            DispatchQueue.main.async { binding.wrappedValue = h }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var host: HeightReportingHostingView<Content>? }
}

/// An `NSHostingView` that fires `onLayout` after each AppKit layout pass. The
/// menu panel uses it because collapsing or expanding a section flips state inside
/// this view's own SwiftUI graph and never re-runs the surrounding `updateNSView`
/// — so the height has to be read from here, where the change actually lands.
private final class HeightReportingHostingView<Content: View>: NSHostingView<Content> {
    var onLayout: (() -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - Keep awake

struct KeepAwakeCard: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var awake = KeepAwakeManager.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.defaultDuration) private var defaultDuration: Int = 0
    @AppStorage(DefaultsKey.keepAwakeAutoStart) private var keepAwakeAutoStart = false
    @AppStorage(DefaultsKey.keepAwakeAllowDisplaySleep) private var keepAwakeAllowDisplaySleep = false
    @AppStorage(DefaultsKey.keepAwakeExternalDisplay) private var keepAwakeExternalDisplay = false
    @AppStorage(DefaultsKey.keepAwakeConnectedToPower) private var keepAwakeConnectedToPower = false
    @AppStorage(DefaultsKey.keepAwakeRunningApps) private var keepAwakeRunningApps = false
    @AppStorage(DefaultsKey.keepAwakePauseWhenLocked) private var keepAwakePauseWhenLocked = false
    @AppStorage(DefaultsKey.keepAwakeIconTint) private var keepAwakeIconTint = KeepAwakeIconTint.orange.rawValue
    @AppStorage(DefaultsKey.keepAwakeActiveIcon) private var keepAwakeActiveIcon = KeepAwakeActiveIcon.brim.rawValue
    @AppStorage(DefaultsKey.keepAwakeMouseJiggleEnabled) private var keepAwakeMouseJiggle = false
    @AppStorage(DefaultsKey.keepAwakeMouseJiggleInterval) private var keepAwakeMouseJiggleInterval = 5
    @State private var optionsExpanded = false
    @State private var automationExpanded = false
    /// The last started end time, which the popover opens on.
    @AppStorage(DefaultsKey.keepAwakeUntilTime) private var savedUntilTime = 0.0
    /// An edit not started yet; only starting saves it, so the switch keeps
    /// restarting the session that actually ran.
    @State private var untilDraft: Date?

    /// Only the hour and minute matter; `resolvedUntilDate` picks the next one.
    private var untilTime: Binding<Date> {
        Binding(
            get: {
                untilDraft ?? (savedUntilTime > 0 ? Date(timeIntervalSinceReferenceDate: savedUntilTime)
                    : Date().addingTimeInterval(3600))
            },
            set: { untilDraft = $0 }
        )
    }
    var collapsible = true

    var body: some View {
        // The collapsible header supplies the "Keep awake" title, so the card's
        // first row is just the live status and the on/off switch.
        PanelSection(.keepAwake, title: l10n.s.keepAwakeTitle, collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if awake.isActive, awake.endDate != nil {
                        // Beside the extend chips a narrow panel has no room for the
                        // status; the highlighted chip already shows the countdown
                        // or the end time.
                        ViewThatFits(in: .horizontal) {
                            statusLine.fixedSize()
                            Color.clear.frame(width: 0, height: 0)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            ForEach([15, 30, 60], id: \.self) { minutes in
                                Button("+" + DurationPicker.shortTitle(for: minutes, l10n.s, l10n.language)) {
                                    awake.extend(minutes: minutes)
                                }
                                .buttonStyle(KeepAwakeChipStyle())
                                .fixedSize()
                            }
                        }
                    } else {
                        // Without the extend chips a long status, such as the
                        // conditions of an automatic session, wraps instead.
                        statusLine
                        Spacer(minLength: 4)
                    }
                    Toggle(l10n.s.keepAwakeTitle, isOn: activeBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                // One click starts (or switches) a session; clicking the
                // highlighted chip stops it. The switch reuses the last pick.
                // The menu bar panel is narrower than the island, so the row
                // folds into two rows of four when a single row would truncate.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        ForEach(DurationPicker.choices, id: \.self, content: durationChip)
                        untilChip
                    }
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            ForEach(DurationPicker.choices.prefix(4), id: \.self, content: durationChip)
                        }
                        HStack(spacing: 4) {
                            ForEach(DurationPicker.choices.dropFirst(4), id: \.self, content: durationChip)
                            untilChip
                        }
                    }
                }

                // Shown in both states so starting or stopping never changes
                // the card's height (the panel would jump). Battery protection
                // ends a session the moment it starts, so say why a chip
                // seems to do nothing.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    if let percent = awake.batteryProtectionPercent() {
                        Label(batteryNote(percent), systemImage: "battery.25percent")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    } else {
                        Text(chipHint)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                optionsDisclosure

                Divider()

                optionRow(title: l10n.s.clamshellTitle,
                          caption: clamshellCaption,
                          isOn: $awake.clamshellPreferred,
                          disabled: awake.clamshellSetupInProgress,
                          captionIsError: awake.clamshellSetupFailed)
            }
            .panelCard()
        }
        .onAppear {
            defaultDuration = Defaults.sanitizedDefaultDuration(defaultDuration)
            keepAwakeIconTint = Defaults.sanitizedKeepAwakeIconTint(keepAwakeIconTint).rawValue
            keepAwakeActiveIcon = Defaults.sanitizedKeepAwakeActiveIcon(keepAwakeActiveIcon).rawValue
            keepAwakeMouseJiggleInterval = Defaults.sanitizedKeepAwakeMouseJiggleInterval(keepAwakeMouseJiggleInterval)
        }
    }

    private var optionsDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                optionsExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: optionsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(l10n.s.keepAwakeOptions)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if optionsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    KeepAwakeIconPicker(iconValue: $keepAwakeActiveIcon,
                                        tintValue: $keepAwakeIconTint,
                                        compact: true)
                    compactOptionToggle(
                        icon: "display",
                        title: displaySleepStrings.allowDisplaySleep,
                        isOn: $keepAwakeAllowDisplaySleep
                    )
                    compactOptionToggle(
                        icon: "play.circle",
                        title: l10n.s.keepAwakeAutoStart,
                        isOn: $keepAwakeAutoStart
                    )
                    automationDisclosure
                    compactOptionToggle(
                        icon: "cursorarrow.motionlines",
                        title: l10n.s.keepAwakeMouseJiggle,
                        isOn: $keepAwakeMouseJiggle,
                        errorText: mouseJiggleNeedsAccessibility ? mouseJiggleCaption : nil
                    )
                    if keepAwakeMouseJiggle {
                        mouseJiggleIntervalRow
                        if mouseJiggleNeedsAccessibility {
                            Button(l10n.s.permissionRequest) {
                                grantAccessibility()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.leading, 19)
            }
        }
    }

    private var automationDisclosure: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                automationExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 15)
                    Text(automationStrings.automationSection)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    automationSummaryBadges
                    Image(systemName: automationExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if automationExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    KeepAwakeAutomationEditor(compact: true)
                    compactOptionToggle(
                        icon: "lock.fill",
                        title: automationStrings.pauseWhenLockedToggle,
                        isOn: $keepAwakePauseWhenLocked
                    )
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private var automationSummaryBadges: some View {
        if !keepAwakeExternalDisplay,
           !keepAwakeConnectedToPower,
           !keepAwakeRunningApps,
           !keepAwakePauseWhenLocked {
            Text(automationStrings.automationOff)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 4) {
                if keepAwakeExternalDisplay {
                    automationSystemBadge("display")
                }
                if keepAwakeConnectedToPower {
                    automationSystemBadge("powerplug.fill")
                }
                if keepAwakeRunningApps {
                    automationSystemBadge("app.fill")
                }
                if keepAwakePauseWhenLocked {
                    automationSystemBadge("lock.fill")
                }
            }
        }
    }

    private func automationSystemBadge(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 17, height: 17)
            .background(Circle().fill(Color.accentColor.opacity(0.12)))
    }

    private func compactOptionToggle(icon: String,
                                     title: String,
                                     isOn: Binding<Bool>,
                                     errorText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mouseJiggleIntervalRow: some View {
        HStack(spacing: 8) {
            Text(l10n.s.keepAwakeMouseJiggleInterval)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            KeepAwakeMouseJiggleIntervalPicker(selection: $keepAwakeMouseJiggleInterval)
        }
    }

    private var mouseJiggleNeedsAccessibility: Bool {
        keepAwakeMouseJiggle && !permissions.accessibility
    }

    private var mouseJiggleCaption: String {
        mouseJiggleNeedsAccessibility
            ? "\(l10n.s.permissionRequired): \(l10n.s.permissionAccessibility)"
            : l10n.s.keepAwakeMouseJiggleCaption
    }

    private var statusLine: some View {
        Group {
            if awake.isActive {
                if awake.sessionTrigger == .automation {
                    Text(automationStrings.activeStatus(for: awake.activeAutomationConditions))
                } else if let end = awake.endDate {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(l10n.s.keepAwakeEndsIn) \(Self.remainingText(until: end))")
                    }
                } else {
                    Text(l10n.s.keepAwakeUntilDisabled)
                }
            } else {
                Text(l10n.s.keepAwakeNormalRules)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func durationChip(_ minutes: Int) -> some View {
        let selected = showsSessionPick && awake.sessionMinutes == minutes
        return Button {
            if selected {
                awake.toggle()
            } else {
                awake.activate(minutes: minutes)
            }
        } label: {
            // Every timed chip reserves "0:00:00", so ViewThatFits measures the
            // countdown and neither a start nor an extend can overflow the row.
            ZStack {
                Text(DurationPicker.shortTitle(for: minutes, l10n.s, l10n.language))
                if minutes > 0 {
                    Text("0:00:00").hidden()
                }
            }
                .opacity(selected && awake.endDate != nil ? 0 : 1)
                .overlay {
                    if selected, let end = awake.endDate {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Self.countdownText(until: end))
                                .fixedSize()
                        }
                    }
                }
        }
        .buttonStyle(KeepAwakeChipStyle(isSelected: selected))
        .accessibilityLabel(DurationPicker.title(for: minutes, l10n.s))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var untilChip: some View {
        KeepAwakeEndTimePicker(selection: untilTime,
                               activeEnd: showsSessionPick && awake.sessionMinutes == nil ? awake.endDate : nil,
                               onStop: { awake.toggle() }) {
            awake.activate(until: KeepAwakeAutomationSupport.resolvedUntilDate(picked: untilTime.wrappedValue, now: Date()))
            untilDraft = nil
        }
    }

    private var showsSessionPick: Bool {
        awake.isActive && awake.sessionTrigger != .automation
    }

    /// "58:12" or "1:05:12" for the highlighted chip.
    static func countdownText(until end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSinceNow))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func batteryNote(_ percent: Int) -> String {
        switch l10n.language {
        case .enUS: return "Battery at \(percent)%. Plug in or lower the battery limit to start"
        }
    }

    private var chipHint: String {
        switch l10n.language {
        case .enUS: return "Click a chip to start. Click it again to stop"
        }
    }

    private var automationStrings: KeepAwakeAutomationStrings {
        FeatureStrings.keepAwakeAutomation(l10n.language)
    }

    private var displaySleepStrings: KeepAwakeDisplaySleepStrings {
        FeatureStrings.keepAwakeDisplaySleep(l10n.language)
    }

    private var clamshellCaption: String {
        if awake.clamshellSetupInProgress {
            return l10n.s.configuring
        }
        if awake.clamshellSetupFailed {
            return l10n.s.sudoersFailed
        }
        if awake.clamshellActive {
            return l10n.s.clamshellOnCaption
        }
        if awake.clamshellPreferred {
            return l10n.s.clamshellNeedsSession
        }
        return awake.passwordlessClamshell ? l10n.s.clamshellReady : l10n.s.clamshellNeedsPassword
    }

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { awake.isActive },
            set: { on in
                if on {
                    awake.startLastPick()
                } else if awake.isActive {
                    awake.toggle()
                }
            }
        )
    }

    private func grantAccessibility() {
        Permissions.shared.requestAccessibility()
        Permissions.shared.openAccessibilitySettings()
    }

    private func optionRow(title: String,
                           caption: String?,
                           isOn: Binding<Bool>,
                           disabled: Bool,
                           captionIsError: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                if let caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(captionIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(disabled)
        }
    }

    /// "1 h 05 min" style countdown, shared with the Energy page's status line.
    static func remainingText(until end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSinceNow))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d h %02d min", hours, minutes) }
        if minutes > 0 { return String(format: "%d min %02d s", minutes, seconds) }
        return "\(seconds) s"
    }
}

/// Session durations shared by the panel chips and Settings.
enum DurationPicker {
    /// The offered durations in minutes; 0 keeps the session open until it
    /// is switched off.
    static let choices = [15, 30, 60, 120, 240, 480, 0]

    static func title(for minutes: Int, _ s: Strings) -> String {
        switch minutes {
        case 15: return s.minutes15
        case 30: return s.minutes30
        case 60: return s.hour1
        case 120: return s.hours2
        case 240: return s.hours4
        case 480: return s.hours8
        default: return s.indefinite
        }
    }

    /// Chip-sized label ("15m", "1h" in English), localized by Foundation.
    static func shortTitle(for minutes: Int, _ s: Strings, _ language: AppLanguage) -> String {
        guard minutes > 0 else { return "∞" }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: language.rawValue)
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: TimeInterval(minutes * 60)) ?? title(for: minutes, s)
    }
}

/// Capsule chip used for the Keep awake presets and extensions.
struct KeepAwakeChipStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(isSelected
                ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .contentShape(Capsule())
    }
}

struct KeepAwakeMouseJiggleIntervalPicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Defaults.allowedKeepAwakeMouseJiggleIntervals, id: \.self) { minutes in
                Text(Self.label(for: minutes)).tag(minutes)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    static func label(for minutes: Int) -> String {
        "\(minutes) min"
    }
}
