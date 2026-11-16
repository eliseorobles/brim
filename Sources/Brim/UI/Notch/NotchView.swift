// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct NotchView: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchLiquidGlassEnabled) private var glass = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var text: NotchStrings { FeatureStrings.notch(l10n.language) }

    var body: some View {
        surface
            .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .top)
            .foregroundStyle(.white)
            // The window server leaves SwiftUI content that ignores hit tests
            // out of its own hit test unless it is fully opaque. The backdrop
            // ignores them (allowsHitTesting(false) in NotchSurfaceBackground),
            // and open glass has no opaque black beneath it, so a click or a
            // wheel over empty glass would reach the window behind: the page
            // stops scrolling between cards and the island loses focus. A fill
            // too faint to see takes hit tests and keeps the surface in this
            // window, as the opaque black of a black island does.
            .background(shape.offset(x: service.surfaceShift).fill(Color.black.opacity(0.01)))
            .contentShape(shape.offset(x: service.surfaceShift))
            // The backdrop is a separate, non-interactive hosting view. Claim
            // empty space here so SwiftUI keeps the taps that land on it. This
            // draws nothing, so it does not hold a click in this window at the
            // window server; the fill above does.
            .onTapGesture { }
            .onChange(of: reduceTransparency) {
                DispatchQueue.main.async { service.refreshPresentation(animated: false) }
            }
            .onChange(of: contrast) {
                DispatchQueue.main.async { service.refreshPresentation(animated: false) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
            .environment(\.notchPresentation, true)
            .environment(\.notchGlassSurface, usesGlassSurface)
            .tint(.white)
            .accessibilityIdentifier("notch.surface")
    }

    private var usesGlassSurface: Bool {
#if compiler(>=6.2)
        if #available(macOS 26, *), glass, !reduceTransparency {
            // Resting wings, compact activities and small status notices keep
            // blending into the physical camera cutout.
            return service.usesGlassSurface
        }
#endif
        return false
    }

    private var shape: NotchShape {
        NotchShape.island(height: service.surfaceSize.height, geometry: service.geometry)
    }

    @ViewBuilder private var surface: some View {
        if service.fullscreenCompact {
            Color.clear.accessibilityHidden(true)
        } else if service.expanded {
            expanded
        } else if let notice = service.stripNotice {
            Button {
                service.activateNotice(notice)
            } label: {
                Group {
                    if floats {
                        // A departing notice keeps its own row while the capsule closes.
                        NotchCapsuleNoticeView(notice: notice, geometry: service.geometry,
                                               size: service.notice == nil ? service.capsuleNoticeSurface(notice)
                                                   : service.surfaceSize)
                    } else {
                        NotchNoticeView(notice: notice, geometry: service.geometry)
                    }
                }
                // Beside a camera the notice reaches further toward its
                // wider side, and takes clicks all the way to its end.
                .contentShape(Rectangle().offset(x: floats ? 0
                    : service.geometry.noticeShift(notice.wings(in: service.geometry))))
            }
            // A floating capsule lights up under the pointer. Beside a
            // camera the wash would outline the housing, so the notch keeps
            // its notices plain, as its other strips are.
            .buttonStyle(NotchButtonStyle(cornerRadius: 14, lifts: false, highlights: floats))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notice.accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { service.activateNotice(notice) }
            .accessibilityHint(text.open)
            .id(notice.clickTarget)
            .transition(.opacity)
        } else if service.peeking {
            HStack {
                navigation
                Spacer(minLength: 8)
                NotchIconButton(symbol: "chevron.down", title: text.open) { service.open() }
            }
            .padding(.horizontal, NotchLayout.horizontalInset).padding(.top, service.geometry.safeContentTop)
        } else if let activity = service.compactActivity {
            if service.showsCompactActivityPicker {
                let layout = service.compactActivityPickerLayout
                VStack(spacing: 0) {
                    let strip = service.compactStripSize(for: activity)
                    ZStack(alignment: .top) {
                        activityStrip(activity, size: strip)
                            .frame(width: strip.width, height: layout.headerHeight, alignment: .top)
                            .id(activity)
                            .transition(.blurReplace)
                    }
                    .frame(height: layout.headerHeight, alignment: .top)
                    NotchActivityPicker(activities: service.compactActivities, selected: activity,
                                        columns: layout.columns, language: l10n.language,
                                        select: service.selectCompactActivity)
                        .padding(.horizontal, NotchActivityPickerLayout.horizontalInset)
                        .padding(.vertical, NotchActivityPickerLayout.verticalInset)
                }
            } else {
                // Hover grows the capsule around its strip, as it grows the
                // notch around its wings. Drawn at the grown size, a strip's
                // marks jumped out at once while the shape still grew.
                let strip = service.compactStripSize(for: activity)
                activityStrip(activity, size: strip)
                    .transition(.opacity)
            }
        } else if floats {
            NotchCapsuleRestingView(service: service, size: service.surfaceSize)
                .transition(.opacity)
        } else {
            compact
                .transition(.opacity)
        }
    }

    /// The island floats as a capsule, whose strips run end to end.
    private var floats: Bool { service.geometry.floats }

    /// `size` is the capsule's; a hanging strip keeps the camera's geometry.
    @ViewBuilder private func activityStrip(_ activity: NotchCompactActivity, size: CGSize) -> some View {
        if floats {
            switch activity {
            case .agents: NotchCapsuleAgentStrip(service: service, size: size)
            case .keepAwake: NotchCapsuleKeepAwakeStrip(service: service, size: size)
            }
        } else {
            // Handed down, the wings stay as they were drawn while a strip
            // whose activity just ended leaves, instead of following the
            // service to an island with no activity, where they are empty.
            let geometry = service.compactActivityGeometry
            switch activity {
            case .agents: NotchAgentStrip(service: service, displayGeometry: geometry)
            case .keepAwake: NotchKeepAwakeStrip(service: service, displayGeometry: geometry)
            }
        }
    }

    private var compact: some View { NotchRestingStrip(service: service) }

    private var showsDetail: Bool { service.showingAppPanel || service.selectedMetric != nil }

    /// The open island names no page. Its top row holds the page's own
    /// controls, beside the camera where they fit, as a phone's island wraps
    /// its camera, and the page takes the rest. Pin, Settings and Close live
    /// in the island's menu, a secondary click away anywhere on it, and
    /// Settings on Command-Comma too.
    private var expanded: some View {
        let geometry = service.expandedGeometry
        let band = NotchBand(geometry: geometry, contentWidth: service.contentSize.width)
        return page
            .frame(width: service.contentSize.width, height: service.contentSize.height, alignment: .top)
            .clipShape(NotchPageClip(top: geometry.pageTopInset))
            // With no title on screen, VoiceOver still names the page.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(pageName)
            // The island's own actions sit in its secondary-click menu, with
            // no button of their own in the row; VoiceOver lists them here.
            .accessibilityAction(named: service.pinned ? text.unpin : text.pin) { service.pinned.toggle() }
            .accessibilityAction(named: l10n.s.menuSettings) { service.openSettings() }
            .accessibilityAction(named: text.collapse) { service.collapse() }
            .padding(.top, geometry.pageTopInset - geometry.headerTopInset)
            .overlayPreferenceValue(NotchBandKey.self, alignment: .top) { items in
                if geometry.headerRowHeight > 0 {
                    bandRow(items, band: band)
                }
            }
            .environment(\.notchBand, band)
            .padding(.horizontal, NotchLayout.horizontalInset)
            .padding(.top, geometry.headerTopInset)
            .padding(.bottom, NotchLayout.bottomInset)
            .frame(width: service.expandedSize.width, height: service.expandedSize.height, alignment: .top)
            .contentShape(Rectangle())
            .contextMenu { islandMenu }
            // Opening the island makes its panel key, so Keyboard navigation would ring
            // the first control. Show the ring once keyboard input begins.
            .focusEffectDisabled(!service.showsKeyboardFocus)
    }

    private var pageName: String {
        if service.showingSections { return text.sectionsTitle }
        if showsDetail || service.modules.isEmpty { return service.detailTitle }
        return service.selected.title(l10n.language)
    }

    @ViewBuilder private var page: some View {
        if service.showingSections {
            NotchSectionsView(service: service)
        } else if scrollsVertically {
            ScrollView {
                content
                    .frame(height: contentOverflows ? pageSize.height : nil)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
            }
            .scrollIndicators(.automatic)
            .notchScrollEdgeFade()
        } else {
            content
        }
    }

    /// The row: the island's way back or to the sections leads it, and the
    /// pin ends it, around what the page puts there.
    private func bandRow(_ items: NotchBandItems, band: NotchBand) -> some View {
        NotchBandRow(band: band) {
            bandLeading(band)
            items.leading
        } trailing: {
            // The island's own marks follow the page's controls while they
            // fit their side, never pushing them under the camera; the menu
            // offers the same actions either way.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { items.trailing; pinMark }
                items.trailing
            }
        }
        // Drawn here rather than in the page, the row's controls read the
        // island's language for their dates and numbers, as the page does.
        .environment(\.locale, l10n.language.formattingLocale())
    }

    /// A kept-open island says so, and one click lets it go.
    @ViewBuilder private var pinMark: some View {
        if service.pinned {
            NotchIconButton(symbol: "pin.fill", title: text.unpin, selected: true) { service.pinned = false }
        }
    }

    @ViewBuilder private func bandLeading(_ band: NotchBand) -> some View {
        if service.showingSections {
            NotchIconButton(symbol: "chevron.left", title: l10n.s.obBack, action: service.toggleSections)
            // Beside the camera the field takes the rest of its side.
            NotchSectionSearch(service: service, maximumFieldWidth: band.besideCamera ? .infinity : 150)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if showsDetail {
            NotchBandBackButton(title: service.detailTitle, action: service.goBack)
        } else if band.sectionsButton {
            // Without the floating button, the sections stay one click away;
            // the row keeps it room before the page's own controls.
            NotchSectionsButton(action: service.toggleSections)
        }
    }

    /// The island's own actions, on a secondary click anywhere a page has no
    /// menu of its own. The floating buttons and the keys reach them too.
    @ViewBuilder private var islandMenu: some View {
        if !service.modules.isEmpty {
            Button(action: service.toggleSections) {
                Label(service.showingSections ? l10n.s.obBack : text.sectionsTitle, systemImage: "square.grid.2x2")
            }
        }
        Button {
            service.pinned.toggle()
        } label: {
            Label(service.pinned ? text.unpin : text.pin, systemImage: service.pinned ? "pin.slash" : "pin")
        }
        Button(action: service.openSettings) {
            Label(l10n.s.menuSettings, systemImage: "gearshape")
        }
        Divider()
        Button(action: service.collapse) {
            Label(text.collapse, systemImage: "chevron.up")
        }
    }

    /// Keep each page's minimum usable layout reachable when a custom height
    /// or the display leaves less room. The outer silhouette stays unchanged.
    private var pageSize: CGSize {
        var size = service.contentSize
        guard !showsDetail else { return size }
        switch service.selected {
        case .controls:
            size.height = max(size.height, NotchLayout.controls(
                shortcutCount: NotchSupport.controls().count, width: size.width, height: size.height).height)
        case .clipboard:
            // A complete card with its action row; the search is in the top row.
            size.height = max(size.height, NotchLayout.clipboardCardHeight)
        case .system, .agents: break
        }
        return size
    }

    private var contentOverflows: Bool { pageSize.height > service.contentSize.height }

    private var scrollsVertically: Bool {
        guard !service.showingAppPanel else { return false }
        return contentOverflows || service.selectedMetric != nil
    }

    private var navigationTitle: String {
        let destination = service.reopeningDestination
        return destination.appPanel || destination.sections
            ? text.sectionsTitle : destination.module.title(l10n.language)
    }

    private var navigation: some View {
        Button(action: service.toggleSections) {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(navigationTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: NotchLayout.navigationHeight)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 12, lifts: false))
        .accessibilityLabel(text.switchSection)
        .accessibilityValue(navigationTitle)
        .accessibilityIdentifier("notch.navigation")
        .help(text.switchSection + "  ⌘K")
    }

    @ViewBuilder private var content: some View {
        if service.showingAppPanel {
            MenuPanelView(notchSize: pageSize)
        } else if let metric = service.selectedMetric {
            if metric == .fan {
                NotchFanControlView()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { service.updateFanDetailHeight($0) }
            } else {
                MetricDetailView(kind: metric)
            }
        } else if service.modules.isEmpty {
            NotchEmptyView(symbol: "slider.horizontal.3", message: text.empty) {
                NotchPillButton(title: l10n.s.menuSettings, prominent: true, action: service.openSettings)
            }
        } else {
            switch service.selected {
            case .controls: NotchControlsView(service: service, size: pageSize)
            case .clipboard: NotchClipboardView(service: service, size: pageSize)
            case .system:
                NotchSystemView(size: pageSize) { service.showMetric($0) }
            case .agents: NotchAgentsView(size: pageSize)
            }
        }
    }
}

/// Read-only RPM telemetry stays available when the protected fan helper fails.
private struct NotchFanControlView: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        FanControlSection(collapsible: false, fallbackFanSpeeds: monitor.snapshot.fanSpeeds)
    }
}

/// The charge the closed island rests with, beside a camera or in the capsule.
enum NotchRestingBattery {
    /// Both halves of the charge turn amber, then red, together as it runs low.
    static func tint(for power: PowerReading, tint: Bool, threshold: Int,
                     early: Bool, earlyThreshold: Int) -> Color {
        switch NotchSupport.batteryWarning(percent: power.chargePercent,
                                           externalConnected: power.externalConnected,
                                           tint: tint, threshold: threshold,
                                           early: early, earlyThreshold: earlyThreshold) {
        case .low: return .red
        case .early: return .orange
        case .none: return .white.opacity(0.9)
        }
    }

    /// The icon empties with the charge, as the menu bar's does.
    static func symbol(for power: PowerReading) -> String {
        BatteryPowerSupport.menuBarSymbol(percent: power.chargePercent ?? 100,
                                          isCharging: power.isCharging,
                                          externalConnected: power.externalConnected)
    }
}

/// The closed island at rest beside a camera: the wings with the charge or
/// the AI allowance the person chose, when the menus leave room.
struct NotchRestingStrip: View {
    @ObservedObject var service: NotchService
    /// Another display's strip, when the island shows on every display.
    var displayGeometry: NotchGeometry? = nil
    @AppStorage(DefaultsKey.notchLowBatteryTint) private var lowBatteryTint = false
    @AppStorage(DefaultsKey.notchLowBatteryThreshold) private var lowBatteryThreshold = NotchSupport.defaultLowBatteryThreshold
    @AppStorage(DefaultsKey.notchLowBatteryEarly) private var earlyBatteryWarning = false
    @AppStorage(DefaultsKey.notchLowBatteryEarlyThreshold) private var earlyBatteryThreshold = NotchSupport.defaultEarlyBatteryThreshold

    private var geometry: NotchGeometry { displayGeometry ?? service.geometry }

    private var batteryTint: Color {
        NotchRestingBattery.tint(for: service.power, tint: lowBatteryTint, threshold: lowBatteryThreshold,
                                 early: earlyBatteryWarning, earlyThreshold: earlyBatteryThreshold)
    }

    private var batterySymbol: String { NotchRestingBattery.symbol(for: service.power) }

    /// Centre battery content inside the wing's visible area, past its curved shoulder.
    private var restingBatteryInset: CGFloat {
        // Leave enough of the 44-point wing for the full 100% label at every height.
        min(16, NotchLayout.shoulder(height: geometry.stripHeight) + NotchLayout.compactEdgeGap)
    }

    var body: some View {
        HStack(spacing: 0) {
            if service.idleContent != .none, geometry.restingWingWidth > 0 {
                // Each wing keeps its width even when it has nothing to
                // show, or the other one slides toward the camera.
                ZStack(alignment: .trailing) {
                    Color.clear
                    switch service.idleContent {
                    case .battery:
                        Image(systemName: batterySymbol).font(.system(size: 12))
                            .foregroundStyle(batteryTint)
                            .padding(.leading, restingBatteryInset)
                    case .agents:
                        NotchAgentRestingWing(leading: true)
                            .padding(.leading, restingBatteryInset)
                    case .none: EmptyView()
                    }
                }
                .frame(width: geometry.restingWingWidth)
                Color.clear.frame(width: geometry.cameraWidth)
                ZStack(alignment: .leading) {
                    Color.clear
                    switch service.idleContent {
                    case .battery:
                        if let percent = service.power.chargePercent {
                            Text("\(percent)%").font(.system(size: 9, weight: .medium)).monospacedDigit()
                                .foregroundStyle(batteryTint)
                                .lineLimit(1)
                                .padding(.trailing, restingBatteryInset)
                        }
                    case .agents:
                        NotchAgentRestingWing(leading: false)
                            .padding(.trailing, restingBatteryInset)
                    case .none: EmptyView()
                    }
                }
                .frame(width: geometry.restingWingWidth)
            } else { Color.clear }
        }
        .foregroundStyle(.white.opacity(0.9))
        // The strip stays in its band at the top: hover grows the island
        // around it, and centring it in the taller shape dropped it half
        // the growth in one frame.
        .frame(height: geometry.stripHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

struct NotchShape: Shape {
    var attached: Bool
    var radius: CGFloat
    /// A capsule floating this far inside the top and bottom of the rect,
    /// with its own corners, instead of the outline hanging from the edge.
    var floatingGap: CGFloat? = nil
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    /// The island's outline at a surface of `height`, as its display draws it.
    static func island(height: CGFloat, geometry: NotchGeometry) -> NotchShape {
        NotchShape(attached: true, radius: NotchLayout.surfaceRadius(height: height), floatingGap: geometry.floatingGap)
    }

    func path(in rect: CGRect) -> Path {
        guard attached else { return Path(roundedRect: rect, cornerRadius: radius) }
        if let floatingGap { return Path(NotchLayout.capsulePath(in: rect, gap: floatingGap)) }
        let shoulder = NotchLayout.shoulder(height: rect.height)
        let bottom = min(radius, rect.height / 2, (rect.width - shoulder * 2) / 2)
        let tangent: CGFloat = 0.55228475
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addCurve(to: CGPoint(x: rect.width - shoulder, y: shoulder),
                      control1: CGPoint(x: rect.width - shoulder * tangent, y: 0),
                      control2: CGPoint(x: rect.width - shoulder, y: shoulder * (1 - tangent)))
        path.addLine(to: CGPoint(x: rect.width - shoulder, y: rect.height - bottom))
        path.addCurve(to: CGPoint(x: rect.width - shoulder - bottom, y: rect.height),
                      control1: CGPoint(x: rect.width - shoulder, y: rect.height - bottom * (1 - tangent)),
                      control2: CGPoint(x: rect.width - shoulder - bottom * (1 - tangent), y: rect.height))
        path.addLine(to: CGPoint(x: shoulder + bottom, y: rect.height))
        path.addCurve(to: CGPoint(x: shoulder, y: rect.height - bottom),
                      control1: CGPoint(x: shoulder + bottom * (1 - tangent), y: rect.height),
                      control2: CGPoint(x: shoulder, y: rect.height - bottom * (1 - tangent)))
        path.addLine(to: CGPoint(x: shoulder, y: shoulder))
        path.addCurve(to: .zero,
                      control1: CGPoint(x: shoulder, y: shoulder * (1 - tangent)),
                      control2: CGPoint(x: shoulder * tangent, y: 0))
        path.closeSubpath()
        return path
    }
}

extension NotchModule: PanelOrderItem {
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .controls: return FeatureStrings.notch(language).controls
        case .clipboard: return FeatureStrings.clipboard(language).title
        case .system: return FeatureStrings.notch(language).system
        case .agents: return FeatureStrings.notchAgents(language).title
        }
    }
}

/// A page may draw into the island's own margins and behind its header, which
/// the silhouette already bounds: hover growth fades out there instead of
/// ending at a hard edge. The header stays above the page.
private struct NotchPageClip: Shape {
    /// From the top of the page to the top of the island.
    let top: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - NotchLayout.horizontalInset, y: rect.minY - top,
                    width: rect.width + NotchLayout.horizontalInset * 2,
                    height: rect.height + top + NotchLayout.bottomInset))
    }
}

/// Named choices appear below the camera, with the current activity highlighted.
struct NotchActivityPicker: View {
    @Namespace private var choice
    let activities: [NotchCompactActivity]
    let selected: NotchCompactActivity
    let columns: Int
    let language: AppLanguage
    let select: (NotchCompactActivity) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NotchActivityPickerLayout.spacing),
                                 count: columns), spacing: NotchActivityPickerLayout.spacing) {
            ForEach(activities) { activity in
                let chosen = activity == selected
                Button { select(activity) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: activity.symbol)
                        Text(activity.title(language)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: NotchActivityPickerLayout.rowHeight)
                    .foregroundStyle(chosen ? Color.black : Color.white)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12))
                            if chosen {
                                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                                    .matchedGeometryEffect(id: "choice", in: choice)
                            }
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(activity.title(language))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("notch.activity.\(activity.rawValue)")
            }
        }
    }
}
