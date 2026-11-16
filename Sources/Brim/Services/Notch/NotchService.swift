// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import IOKit.ps
import SwiftUI

struct NotchNotice: Equatable {
    let event: NotchEvent
    let title: String
    let detail: String
    let symbol: String
    /// The agent an AI notice is about, which tints its mark.
    var agent: AgentProvider? = nil

    enum ClickTarget: Hashable {
        case event(NotchEvent, title: String, detail: String)
    }

    /// What a click on this notice does; a notice with other text replaces it.
    var clickTarget: ClickTarget { .event(event, title: title, detail: detail) }

    /// Each side as wide as what it shows, so neither ends in a band of
    /// empty black: the island reaches further toward its wider side.
    var preferredWings: NotchNoticeWings {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        func measured(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let leading = measured(title)
        func fitted(_ content: CGFloat) -> CGFloat { min(240, max(Self.minimumWing, ceil(content) + 16 + cameraGap)) }
        // An empty title leaves the mark alone, without the space after it.
        let mark = fitted(leading > 0 ? leading + 18 + 8 : 18)
        return NotchNoticeWings(leading: mark, trailing: fitted(measured(detail)))
    }

    /// The sides this notice takes beside a camera, as its strip draws them.
    func wings(in geometry: NotchGeometry) -> NotchNoticeWings {
        geometry.noticeWings(preferredWings)
    }

    /// The narrowest side a text notice keeps: its curved end and some air.
    static let minimumWing: CGFloat = 36

    /// Room text keeps from the camera; battery labels need breathing room
    /// at both the curved edge and the camera. Two lines of text sit at the
    /// island's two ends, each as far from its curved edge, so a short one
    /// leaves its spare room beside the camera rather than at one end.
    var cameraGap: CGFloat { event == .battery ? 16 : 6 }

    var accessibilityText: String {
        [title, detail].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// From the island's curved end to the words.
    static let endInset: CGFloat = 16

    /// Room a closed notice keeps inside its curved ends, which a side as
    /// narrow as its content still clears; only a display too narrow for a
    /// side's content takes some of it.
    func inset(wing: CGFloat) -> CGFloat {
        min(Self.endInset, wing / 2)
    }
}

/// Owns presentation only. The clipboard, the agents and metrics keep their
/// original owners, gates and privacy rules.
final class NotchService: ObservableObject {
    static let shared = NotchService()
    static let fullscreenVisibilityDidChange = Notification.Name("NotchFullscreenVisibilityDidChange")

    @Published private(set) var geometry = NotchGeometry(
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0, cameraWidth: 0)
    @Published private(set) var expanded = false
    @Published private(set) var showsKeyboardFocus = false
    /// True when macOS refused the island's own shortcut, so Settings can say so.
    @Published private(set) var shortcutRegistrationFailed = false
    private let hotkey = QuickToolHotkey(id: 81)
    @Published private(set) var peeking = false
    @Published private(set) var selectedMetric: MetricDetailKind?
    @Published var pinned = false
    @Published private(set) var selected: NotchModule = .controls
    @Published private(set) var showingAppPanel = false
    @Published private(set) var showingSections = false
    @Published private(set) var sectionQuery = ""
    @Published var highlightedSection: NotchModule? { didSet { revealHighlightedSection() } }
    /// The gallery's first visible row; the rows above it have stepped away.
    @Published private(set) var sectionRow = 0
    @Published private(set) var modules: [NotchModule] = []
    @Published private(set) var notice: NotchNotice?
    /// A compact notice stays drawn while the island closes around it.
    @Published private(set) var departingNotice: NotchNotice?
    /// The clipboard page keeps its filter here, and the top row's magnifier
    /// asks it to open the search, so both can sit in the row and not in the page.
    /// The filter lasts one opening, as it did while the page kept it.
    @Published var clipboardPinnedOnly = false
    @Published private(set) var clipboardSearchRequest = 0
    func requestClipboardSearch() { clipboardSearchRequest += 1 }
    /// The last ⌘1–⌘9 pressed on the Clipboard page, which the page turns
    /// into a paste of the entry at that place.
    @Published private(set) var clipboardPastePress: NotchClipboardPastePress?
    /// Whether the island panel holds the keyboard. Opened by hover, or left
    /// open while another app is active, it does not, and its shortcuts then
    /// reach the app in front instead.
    @Published private(set) var panelIsKey = false
    /// Kept after closing, so the next Fan Control detail opens at its size.
    @Published private var fanDetailHeight: CGFloat?
    @Published private(set) var power = PowerReading()

    private var windowHost: NotchWindowHost?
    private var panel: NotchPanel? { windowHost?.panel }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var subscriptions = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []
    private var screenEdgeClickMonitors: [Any] = []
    private var screenEdgePress: (area: CGRect, point: CGPoint, notice: NotchNotice?)?
    private var hiddenHoverMonitors: [Any] = []
    private var hoverExitMonitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    /// Set by a notice that replaces one of its own kind, for the refresh it
    /// triggers, so the island eases to the new width rather than springing.
    private var noticeFitsInPlace = false
    private var noticeWork: DispatchWorkItem?
    private var departureWork: DispatchWorkItem?
    private var powerSource: CFRunLoopSource?
    private var powerSampler: PowerSampler?
    private var inside = false
    private var hoverEmphasized = false
    private var activitySelection = NotchActivitySelection()
    private var hoverState = NotchHoverState()
    private var openedByHover = false
    /// A click inside the open island, which may be what brings another app forward.
    private var clickedSinceOpening = false
    /// Whether the open detail was reached from inside the island, so Escape
    /// steps back to its page as the Back button does. A detail the island
    /// opened on, from the menu bar for instance, has nothing behind it and
    /// closes like the menu panel.
    private var detailHasPage = false
    /// What a page shows over its own content, such as the month grid, and
    /// how to close it; Escape closes it before the page.
    private var pageLayers: [NotchModule: () -> Void] = [:]
    private var trackingMenu = false
    /// The home page's controls as the preferences last saved them, read with
    /// the preferences: the open page's geometry is read on every layout pass.
    private var homeControls: [NotchControlItem] = []
    /// A click away or another app activating leaves the island up while
    /// it is pinned, a menu tracks, or a sheet or chooser hangs beside it.
    private var keepsWorkingSurface: Bool { keepsSurfaceOnClick }
    private var keepsSurfaceOnClick: Bool {
        pinned || trackingMenu || NSApp.modalWindow != nil || panel?.attachedSheet != nil
    }
    /// Up and measuring its display. Settings previews read the island's
    /// size only then.
    private(set) var running = false
    private var session = NotchSessionState()
    private var suspended: Bool { !session.canPresent }
    @Published private(set) var hiddenInFullscreen = false {
        didSet {
            guard hiddenInFullscreen != oldValue else { return }
            NotificationCenter.default.post(name: Self.fullscreenVisibilityDidChange, object: self,
                                            userInfo: ["hidden": hiddenInFullscreen])
        }
    }
    private var settingsSignature = ""
    private var sectionScroll = NotchSectionScroll()
    /// The source the layout notice last read, so a repeated announcement of
    /// the same source, and the one the system posts at launch, say nothing.
    private var inputSourceID: String?
    private var notchNeedsMonitor = false
    private var menuSpaceTimer: Timer?
    private var appFullscreenTimer: Timer?
    private var appFullscreenDisplays: Set<CGDirectDisplayID> = []
    /// Whether a full-screen Space, not an app's own full screen, hides the island.
    private var hiddenByFullscreenSpace = false
    /// Set while an app's own full screen ends, so the hidden island returns with motion.
    private var revealingFromAppFullscreen = false
    private var menuSpaceReading = false
    private var menuSpaceGeneration = 0
    private var menuBarMeasurements = NotchMenuBarMeasurements()
    private var screenRefreshWork: DispatchWorkItem?
    private var preferenceSyncWork: DispatchWorkItem?
    private let menuSpaceQueue = DispatchQueue(label: "com.roblesconsulting.brim.notch-menu-space", qos: .utility)
    /// Set while the live window is on its way to another display, so the copy
    /// there stays up until that window has been drawn for it and ordered in.
    private var mirrorHeldForArrival: CGDirectDisplayID?
    /// Bumped on every move, so a reveal queued for the display just left does
    /// not order the window in after a newer move, or after the island stops.
    private var relocationTicket = 0
    /// The display the island is on. The pointer choice keeps it there until
    /// the island rests, so a preference sync never moves an open island.
    private var displayID: CGDirectDisplayID?
    private var followsPointer = false
    /// Every other display shows a copy of the closed island.
    private var showsOnAllDisplays = false
    private var mirrors: [CGDirectDisplayID: NotchMirror] = [:]
    /// Displays in full screen, a Space or an app's own, read as it changes.
    private var fullscreenDisplays: Set<CGDirectDisplayID> = []
    /// The part of `fullscreenDisplays` that shows a full-screen Space.
    private var fullscreenSpaceDisplays: Set<CGDirectDisplayID> = []
    /// Copies an app's own full screen hid with motion, so they return with it.
    private var mirrorsHiddenByApp: Set<CGDirectDisplayID> = []
    private var pointerMonitors: [Any] = []
    private var pointerFollowWork: DispatchWorkItem?
    /// How long the pointer stays on another display before the island
    /// follows, so passing over a display edge does not move it.
    private static let pointerFollowDelay: TimeInterval = 0.2

    private init() {
        hotkey.onPress = { [weak self] in self?.toggleFromShortcut() }
    }

    private var hiddenUntilHover: Bool {
        !hiddenInFullscreen && UserDefaults.standard.bool(forKey: DefaultsKey.notchHideUntilHover)
            && UserDefaults.standard.bool(forKey: DefaultsKey.notchOpenOnHover)
            && !expanded && !peeking
            // Set to show activity, it comes into sight while one runs or a
            // notice shows. Closed beside a simulated cutout with no room
            // from the menus, it draws no activity, so it keeps waiting for
            // the pointer to reach its place.
            && !(NotchSupport.hiddenShowsActivity() && (notice != nil
                || compactActivity != nil && (geometry.isNotched || geometry.compactSideRoom != nil)))
    }

    /// Full screen keeps a clickable black cutout until the user opens it.
    var fullscreenCompact: Bool {
        hiddenInFullscreen && !expanded && !peeking
    }

    /// A simulated cutout covers no camera, so in full screen it stays out
    /// of the picture until the configured hover or a shortcut opens it.
    private var hiddenAtRestInFullscreen: Bool {
        fullscreenCompact && !geometry.isNotched
    }

    /// Full-screen hover is opt-in independently of the opening mode used
    /// on the desktop. Hiding full-screen content alone never enables it.
    private var hoverOpeningEnabled: Bool {
        hiddenInFullscreen ? UserDefaults.standard.bool(forKey: DefaultsKey.notchHoverInFullscreen)
            : UserDefaults.standard.bool(forKey: DefaultsKey.notchOpenOnHover)
    }

    /// Out of sight at rest, the island has no window for the pointer to
    /// enter, so hover follows the pointer over its place instead.
    private var watchesHiddenHover: Bool {
        hiddenUntilHover || (hiddenAtRestInFullscreen && hoverOpeningEnabled)
    }

    /// A Mac without a battery has no charge to show, so a saved battery
    /// choice rests empty there.
    var idleContent: NotchIdleContent {
        let content = NotchSupport.idleContent()
        return content == .battery && !PowerSampler.hasInternalBattery ? .none : content
    }

    var hasAgentActivity: Bool {
        NotchAgentSupport.showsLiveActivity() && !AgentUsageService.shared.snapshot.live.isEmpty
    }

    var hasKeepAwakeActivity: Bool {
        NotchKeepAwakeSupport.showsActivity() && KeepAwakeManager.shared.isActive
    }

    var compactActivity: NotchCompactActivity? {
        activitySelection.current(available: compactActivities)
    }

    var compactActivities: [NotchCompactActivity] {
        NotchSupport.compactActivities(agents: hasAgentActivity, keepAwake: hasKeepAwakeActivity)
    }

    var showsCompactActivityPicker: Bool {
        inside && !hiddenInFullscreen && !hiddenUntilHover && !expanded && !peeking
            && notice == nil && compactActivities.count > 1
    }

    var compactActivityPickerLayout: NotchActivityPickerLayout {
        let activities = compactActivities
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let labelWidth = activities.map {
            ($0.title(L10n.shared.language) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let sizes = activities.map { compactStripSize(for: $0) }
        // Switching the chosen strip must not move the buttons under the pointer.
        let strip = CGSize(width: sizes.map(\.width).max() ?? geometry.cameraWidth,
                           height: sizes.map(\.height).max() ?? geometry.stripHeight)
        return NotchActivityPickerLayout(count: activities.count, labelWidth: labelWidth,
                                         stripSize: strip, screenWidth: geometry.screen.width)
    }

    func selectCompactActivity(_ activity: NotchCompactActivity) {
        guard compactActivities.contains(activity) else { return }
        hoverWork?.cancel(); hoverWork = nil
        switchCompactSelection {
            activitySelection.select(activity, available: compactActivities)
        }
    }

    /// The picker keeps its size whatever is chosen, so the choice moves inside
    /// the surface, the highlight sliding and the strip changing in place,
    /// instead of the whole content fading through the host.
    private func switchCompactSelection(_ change: () -> Void) {
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .smooth(duration: 0.26)
        withAnimation(animation) {
            objectWillChange.send()
            change()
        }
        refreshPresentation()
    }

    private var compactActivityIsVisible: Bool {
        !fullscreenCompact && !expanded && !peeking && notice == nil && compactActivity != nil
    }

    var compactActivityGeometry: NotchGeometry {
        compactGeometry(for: compactActivity)
    }

    /// On the island's own display unless `base` is another display's.
    private func compactGeometry(for activity: NotchCompactActivity?, base: NotchGeometry? = nil) -> NotchGeometry {
        var geometry = base ?? self.geometry
        if base == nil, showsCompactActivityPicker {
            let room = max(0, (geometry.screen.width - 24 - NotchActivityPickerLayout.horizontalInset * 2
                               - geometry.cameraWidth) / 2)
            geometry.compactSideRoom = min(geometry.compactSideRoom ?? 0, room)
        }
        switch activity {
        case .agents: return geometry.compactAgentGeometry(wing: agentStripWing(in: geometry))
        case .keepAwake: return geometry.compactKeepAwakeGeometry(wing: keepAwakeStripWing(in: geometry))
        case nil: return geometry
        }
    }

    private func keepAwakeStripWing(in geometry: NotchGeometry) -> CGFloat {
        NotchKeepAwakeSupport.stripWing(until: KeepAwakeManager.shared.endDate, now: Date(),
                                        locale: Locale(identifier: L10n.shared.language.rawValue), in: geometry)
    }

    /// The wider of the two sides, the reading or the working agents' marks,
    /// with the clearance from the silhouette's curve that the strip keeps
    /// and air beside the camera.
    private func agentStripWing(in geometry: NotchGeometry) -> CGFloat {
        let provisional = geometry.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.lowerBound)
        let size = NotchAgentSupport.stripTextSize(height: provisional.compactActivityContentHeight)
        let shape = NotchAgentSupport.readingShape(NotchAgentSupport.stripReading(
            AgentUsageService.shared.snapshot, readout: NotchAgentSupport.readout(),
            display: NotchAgentSupport.limitDisplay(), focus: NotchAgentSupport.limitFocus(), now: Date()))
        let width = (shape as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        ]).width
        let reading = width.rounded(.up) + provisional.compactActivityEdgeInset(boxHeight: size * 0.72, radius: 0)
        // The marks on the other side, drawn as the strip draws them: two
        // working agents share a smaller size, each in a frame wider than it.
        let working = Set(AgentUsageService.shared.snapshot.live.map(\.provider)).count
        let mark = CGFloat(working > 1 ? 11 : 14)
        let frame = mark * 1.45 + 1
        let marks = CGFloat(max(1, working)) * frame + CGFloat(max(0, working - 1))
            + provisional.compactActivityEdgeInset(boxHeight: mark + 4, radius: (mark + 4) / 2)
        return max(reading, marks) + NotchAgentSupport.stripCameraGap
    }

    var expandedSize: CGSize {
        if showingSections {
            return geometry.sectionPickerSize(count: filteredSections.count)
        }
        return pageSize(in: expandedGeometry, module: selected,
                        detail: selectedMetric != nil, panel: showingAppPanel,
                        detailHeight: selectedMetric == .fan ? fanDetailHeight : nil)
    }

    /// The open island as Settings previews a section: at rest, with no
    /// detail or app panel in front of the page.
    func previewSize(for module: NotchModule) -> CGSize {
        pageSize(in: previewGeometry(for: module), module: module, detail: false, panel: false, detailHeight: nil)
    }

    /// The island around a previewed section, with the top row its page has.
    /// Settings previews the island while it is off too, when the floating
    /// buttons are not read for it, so a preview reads them as it draws.
    func previewGeometry(for module: NotchModule) -> NotchGeometry {
        geometry.page(module, controls: NotchSupport.controls(),
                      sectionsButton: !NotchQuickAccessConfiguration.current().actions.contains(.explore))
    }

    /// The tallest island a preview can show: a page that fills the budget
    /// below its row.
    var previewLargestSize: CGSize { previewGeometry(for: .clipboard).expandedSize(module: .clipboard) }

    private func pageSize(in geometry: NotchGeometry, module: NotchModule, detail: Bool, panel: Bool,
                          detailHeight: CGFloat?) -> CGSize {
        geometry.expandedSize(module: module, detail: detail, panel: panel, detailHeight: detailHeight,
                              shortcutCount: NotchSupport.controls().count,
                              systemCards: NotchSupport.systemCardCount(hasBattery: PowerSampler.hasInternalBattery,
                                                                        fans: SystemMonitor.shared.snapshot.fanSpeeds.count),
                              agentsHeight: module == .agents && !detail && !panel
                                 ? agentsContentHeight(width: geometry.contentWidth) : nil)
    }

    /// The AI page is as tall as the cards it shows; nil while the logs are
    /// first read, when the page fills the island with its progress.
    private func agentsContentHeight(width: CGFloat) -> CGFloat? {
        let usage = AgentUsageService.shared.snapshot
        let enabled = NotchAgentSupport.providers()
        // Added Codex accounts have cards before, or without, any log.
        let accounts = NotchAgentSupport.showsCodexAccounts() ? CodexProfileLimitsService.shared.states.map(\.id) : []
        // A card per Claude account (ClaudeAccountsService).
        let claudeAccounts = ClaudeAccountsService.accountIDs()
        guard usage.loaded || !accounts.isEmpty else { return nil }
        let providers = enabled.filter { usage.seen.contains($0) || ($0 == .codex && !accounts.isEmpty)
            || ($0 == .claude && claudeAccounts.count > 1) }
        guard !providers.isEmpty else { return 0 }
        return NotchAgentSupport.contentHeight(NotchAgentSupport.rows(
            NotchAgentSupport.tiles(cards: NotchAgentSupport.cards(), providers: providers, codexAccounts: accounts,
                                    claudeAccounts: claudeAccounts),
            width: width))
    }
    var expandedGeometry: NotchGeometry {
        var result = geometry
        result.pageTop = expandedPageTop
        // Under a preset each page takes the width it needs, up to the
        // preset's; the gallery, details and the empty island keep the chosen
        // width, and lead their row with their own way back instead of the
        // sections.
        if !showingSections, !showingAppPanel, selectedMetric == nil, !modules.isEmpty {
            result.pageContentWidth = NotchLayout.naturalContentWidth(selected, controls: homeControls,
                                                                      within: geometry.contentWidth)
        } else {
            result.sectionsButtonInRow = false
        }
        return result
    }
    /// The gallery keeps its search in the top row and a detail its way
    /// back; with no sections the island shows only how to add them.
    private var expandedPageTop: NotchPageTop {
        if showingSections || showingAppPanel || selectedMetric != nil { return .row }
        return modules.isEmpty ? .none : selected.pageTop
    }
    /// A detail's title, the app panel's, or the island's own with no sections.
    var detailTitle: String {
        if showingAppPanel { return "Brim" }
        let language = L10n.shared.language
        guard let metric = selectedMetric else { return FeatureStrings.notch(language).title }
        // The fan card opens Fan Control, so its page shares that title.
        return metric == .fan ? FeatureStrings.fanControl(language).title : metric.title(L10n.shared.s)
    }
    var contentSize: CGSize { expandedGeometry.contentSize(for: expandedSize) }
    var usesGlassSurface: Bool {
        expanded || peeking
    }

    var surfaceSize: CGSize {
        if let capsule = capsuleSurfaceSize { return capsule }
        if fullscreenCompact { return geometry.bareCutout }
        if expanded { return expandedSize }
        if let notice { return geometry.noticeSize(wings: notice.wings(in: geometry)) }
        if peeking { return geometry.peek }
        if showsCompactActivityPicker { return compactActivityPickerLayout.size }
        if compactActivity != nil {
            let resting = compactActivityGeometry.compactActivitySize
            return hoverEmphasized ? NotchHoverEmphasis.size(from: resting, geometry: geometry) : resting
        }
        let resting = geometry.restingSize(showsContent: idleContent != .none)
        return hoverEmphasized ? NotchHoverEmphasis.size(from: resting, geometry: geometry) : resting
    }

    /// How far the island's centre sits right of the camera's. Only a closed
    /// notice beside a camera reaches further toward its wider side. A
    /// capsule runs its strips end to end.
    var surfaceShift: CGFloat {
        guard !geometry.floats, !fullscreenCompact, !expanded, let notice else { return 0 }
        return geometry.noticeShift(notice.wings(in: geometry))
    }

    /// A floating capsule's closed strips run from one round end to the
    /// other and are as wide as what they show. Open, peeking or choosing an
    /// activity, it takes the island's own sizes. Nil when the island hangs.
    private var capsuleSurfaceSize: CGSize? {
        guard geometry.floats, !fullscreenCompact, !expanded else { return nil }
        if let notice { return capsuleNoticeSurface(notice) }
        if peeking || showsCompactActivityPicker { return nil }
        // At rest the charge or the allowance fits inside the bare capsule.
        let resting = compactActivity.map { capsuleStripSize(for: $0) }
            ?? geometry.restingSize(showsContent: false)
        return hoverEmphasized ? NotchHoverEmphasis.size(from: resting, geometry: geometry) : resting
    }

    /// A notice's own capsule, which it keeps while the island closes around it.
    func capsuleNoticeSurface(_ notice: NotchNotice) -> CGSize {
        let layout = NotchCapsuleLayout.self
        return layout.surface(content: layout.noticeContent(title: notice.title, detail: notice.detail),
                              maximum: layout.Maximum.notice, geometry: geometry)
    }

    /// The closed strip an activity takes on its own: a capsule as wide as
    /// what it shows, or the hanging strip around the camera.
    func compactStripSize(for activity: NotchCompactActivity) -> CGSize {
        geometry.floats ? capsuleStripSize(for: activity) : compactGeometry(for: activity).compactActivitySize
    }

    /// Measured from what the capsule's views show, with their own measures,
    /// on the island's display unless `geometry` is another display's.
    private func capsuleStripSize(for activity: NotchCompactActivity, geometry: NotchGeometry? = nil) -> CGSize {
        let geometry = geometry ?? self.geometry
        let layout = NotchCapsuleLayout.self
        let language = L10n.shared.language
        let working = Set(AgentUsageService.shared.snapshot.live.map(\.provider)).count
        switch activity {
        case .agents:
            let reading = NotchAgentSupport.stripReading(AgentUsageService.shared.snapshot, readout: NotchAgentSupport.readout(),
                                                         display: NotchAgentSupport.limitDisplay(),
                                                         focus: NotchAgentSupport.limitFocus(), now: Date())
            return layout.agentSurface(reading: reading, working: working, geometry: geometry)
        case .keepAwake:
            let reading = KeepAwakeManager.shared.endDate.map {
                NotchKeepAwakeSupport.compactText(until: $0, now: Date(), locale: Locale(identifier: language.rawValue))
            }
            return layout.keepAwakeSurface(reading: reading, geometry: geometry)
        }
    }

    var presentationWindow: NSPanel? { panel }
    /// User actions can open the island even when automatic full-screen feedback is hidden.
    var acceptsUserInteraction: Bool {
        running && !suspended && panel != nil
            && windowHost?.isConcealedForMissionControl != true
    }
    var acceptsSystemFeedback: Bool {
        acceptsUserInteraction && !hiddenInFullscreen
    }
    var showsSystemFeedback: Bool {
        acceptsSystemFeedback && (!hiddenUntilHover || NotchSupport.hiddenShowsActivity())
    }

    func syncWithPreferences() {
        preferenceSyncWork?.cancel(); preferenceSyncWork = nil
        guard NotchSupport.isEnabled() else { stop(); return }
        if !running {
            running = true
            installObservers()
        }
        syncShortcut()
        // Paused while the island is away, the section still stops at once
        // when it is turned off.
        if !NotchAgentSupport.isEnabled() { AgentUsageService.shared.stop() }
        guard !suspended else {
            NotchLockScreenService.shared.sync(session)
            return
        }
        // Checked before any service starts, so each preference change while
        // the lid is closed does not start and stop them all again.
        guard screenIndex(in: NSScreen.screens) != nil else { withdrawFromMissingScreen(); return }
        refreshModules()
        homeControls = NotchSupport.controls()
        AgentUsageService.shared.syncWithPreferences()
        followsPointer = displayPreference == .pointer || displayPreference == .all
        showsOnAllDisplays = displayPreference == .all
        updateFullscreenDisplays()
        updateScreen()
        syncAppFullscreenMonitoring()
        syncPointerFollowing()
        panel?.handleScroll = { [weak self] event in self?.handleSectionScroll(event) ?? false }
        let signature = NotchEvent.allCases.map { String(NotchSupport.routes($0)) }.joined()
            + NotchSupport.idleContent().rawValue
            + String(NotchKeepAwakeSupport.showsActivity())
            + modules.map(\.rawValue).joined()
            + String(AppFeature.fanControl.isAvailable)
        if signature != settingsSignature {
            settingsSignature = signature
            bindEvents()
        }
        syncNoticeWithPreferences()
        syncVisibleConsumers()
        refreshPresentation(animated: false)
        // Pages read their preferences as they draw, and a change that keeps
        // the island's size publishes nothing else: hiding a control left the
        // open island, and the preview in Settings, as they were.
        objectWillChange.send()
    }

    /// Like a click on the closed island, the shortcut toggles the island.
    func toggleFromShortcut() {
        guard acceptsUserInteraction else { return }
        toggle()
    }

    /// Registered whenever the island runs, including while it is away, so the
    /// shortcut's state does not flicker with the lid or the lock screen;
    /// `open` already refuses while the island is suspended. Any defaults write
    /// syncs again, so it also waits while another shortcut field is recording,
    /// as the window layout keys do.
    private func syncShortcut() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.notchShortcut, fallback: .notchDefault)
        let failed = !hotkey.sync(enabled: NotchSupport.holdsShortcut() && !ShortcutCapture.isCapturing,
                                  shortcut: shortcut, storageKey: DefaultsKey.notchShortcut)
        if failed != shortcutRegistrationFailed { shortcutRegistrationFailed = failed }
    }

    private func refreshModules() {
        let updated = NotchSupport.modules()
        if modules != updated { modules = updated }
        let selection = modules.contains(selected) ? selected : modules.first ?? .controls
        if selected != selection { selected = selection }
        if let selectedMetric, !metricIsAvailable(selectedMetric) { self.selectedMetric = nil }
    }

    private func metricIsAvailable(_ metric: MetricDetailKind) -> Bool {
        MenuBarMetric.allCases.contains { $0.detailKind == metric && $0.feature.isAvailable }
    }

    func stop() {
        preferenceSyncWork?.cancel(); preferenceSyncWork = nil
        hotkey.unregister()
        if shortcutRegistrationFailed { shortcutRegistrationFailed = false }
        AgentUsageService.shared.stop()
        guard running else { return }
        running = false
        tearDownPresentation()
        NotchLockScreenService.shared.close()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        session = NotchSessionState()
    }

    private func tearDownPresentation() {
        cancelRelocation()
        screenRefreshWork?.cancel(); screenRefreshWork = nil
        stopAppFullscreenMonitoring()
        pageLayers.removeAll()
        clipboardPinnedOnly = false
        panel?.handleScroll = nil
        sectionScroll = NotchSectionScroll()
        stopMenuSpaceMonitoring()
        geometry.compactSideRoom = nil
        hoverWork?.cancel(); hoverWork = nil
        noticeWork?.cancel(); noticeWork = nil
        endDeparture()
        subscriptions.removeAll()
        stopPower()
        AgentUsageService.shared.pause()
        settingsSignature = ""
        expanded = false
        peeking = false
        selectedMetric = nil
        pinned = false
        notice = nil
        showingAppPanel = false
        showingSections = false
        sectionQuery = ""
        highlightedSection = nil
        sectionRow = 0
        inside = false
        hoverEmphasized = false
        activitySelection = NotchActivitySelection()
        hoverState = NotchHoverState()
        openedByHover = false
        removeEventMonitors()
        removeScreenEdgeClickMonitors()
        removeHiddenHoverMonitors()
        removeHoverExitMonitors()
        removePointerMonitors()
        releaseMonitor()
        closeMirrors()
        windowHost?.close()
        windowHost = nil
        // Shown again, an island that follows the pointer starts on its display.
        displayID = nil
        syncPanelKey()
        hiddenInFullscreen = false
        hiddenByFullscreenSpace = false
    }

    /// Opening without a page shows the activity the closed island is
    /// already presenting, unless the user turned that off. Otherwise the
    /// reopening preference decides.
    var reopeningDestination: (module: NotchModule, appPanel: Bool, sections: Bool) {
        if !expanded {
            let opensActivity = UserDefaults.standard.object(forKey: DefaultsKey.notchOpensActivity) as? Bool ?? true
            let activity = opensActivity ? compactActivity?.module : nil
            if let activity, modules.contains(activity) { return (activity, false, false) }
            if UserDefaults.standard.bool(forKey: DefaultsKey.notchReturnHome) {
                let saved = UserDefaults.standard.string(forKey: DefaultsKey.notchHomeModule) ?? ""
                switch NotchReopeningDestination(rawValue: saved) {
                case .appPanel: return (modules.contains(.controls) ? .controls : modules.first ?? .controls, true, false)
                case .explore: return (selected, false, true)
                case nil:
                    let home = NotchModule(rawValue: saved) ?? .controls
                    return (modules.contains(home) ? home : modules.first ?? .controls, false, false)
                }
            }
        }
        return (selected, false, false)
    }

    var reopeningModule: NotchModule {
        reopeningDestination.module
    }

    /// A compact strip opens its activity's page, as opening the island does:
    /// unless the user turned off opening the visible activity, in which case
    /// the reopening choice decides here too.
    func openActivity(_ module: NotchModule) {
        let opensActivity = UserDefaults.standard.object(forKey: DefaultsKey.notchOpensActivity) as? Bool ?? true
        if opensActivity { open(module) } else { open() }
    }

    func open(_ module: NotchModule? = nil, pinned: Bool = false, takeFocus: Bool = true,
              appPanel: Bool = false, metric: MetricDetailKind? = nil, feedback: Bool = true, sections: Bool = false) {
        guard NotchSupport.isEnabled(), !suspended else { return }
        if !running || self.panel == nil { syncWithPreferences() }
        else { refreshModules() }
        guard let panel else { return }
        let reopening = reopeningDestination
        let useReopeningSurface = module == nil && !expanded && !appPanel && !sections && metric == nil
        let destination = module.flatMap { modules.contains($0) ? $0 : nil } ?? reopening.module
        let appPanel = appPanel || (useReopeningSurface && reopening.appPanel)
        let sections = sections || (useReopeningSurface && reopening.sections)
        if useReopeningSurface && reopening.appPanel { MenuPanelFocus.shared.showNormalPanel() }
        if useReopeningSurface && reopening.sections {
            sectionQuery = ""
            sectionRow = 0
            highlightedSection = destination
        }
        let metric = metric.flatMap { metricIsAvailable($0) ? $0 : nil }
        let changesPresentation = !expanded || selected != destination
            || showingAppPanel != appPanel || selectedMetric != metric || showingSections != sections
        (NSApp.delegate as? AppDelegate)?.closePopover(preservingNotch: true)
        if !expanded, modules.contains(.clipboard) { ClipboardHistoryService.shared.rememberPasteTarget() }
        panel.acceptsKeyFocus = true
        hoverState.open()
        hoverWork?.cancel()
        // Entering a detail decides what lies behind it; switching details or
        // passing through the gallery keeps that answer.
        if !expanded {
            detailHasPage = false
            showsKeyboardFocus = false
        }
        else if appPanel || metric != nil, !showingAppPanel, selectedMetric == nil { detailHasPage = true }
        // Following the closed island ends the moment it opens, before a page
        // under the pointer can be told the pointer left.
        // An open page is followed again only from an exit report.
        if !expanded { removeHoverExitMonitors() }
        mutatePresentation(transitionContent: changesPresentation ? (expanded ? .replace : .reveal) : .none) {
            showingAppPanel = appPanel
            showingSections = sections
            if selected != destination { selected = destination }
            if pinned { self.pinned = true }
            selectedMetric = metric
            peeking = false
            openedByHover = !takeFocus
            expanded = true
        }
        inside = windowHost?.containsHover(NSEvent.mouseLocation) == true
        installEventMonitors()
        syncVisibleConsumers()
        if takeFocus { panel.makeKey() }
        if feedback, changesPresentation { provideHapticFeedback() }
    }

    func collapse() {
        hoverState.close(pointerInside: windowHost?.containsHover(NSEvent.mouseLocation) == true)
        pinned = false
        clipboardPinnedOnly = false
        hoverWork?.cancel(); hoverWork = nil
        mutatePresentation(transitionContent: expanded || peeking ? .dismiss : .none) {
            expanded = false
            openedByHover = false
            peeking = false
            selectedMetric = nil
            showingAppPanel = false
            showingSections = false
            sectionQuery = ""
            highlightedSection = nil
            sectionRow = 0
        }
        panel?.acceptsKeyFocus = false
        resignPanelKey()
        removeEventMonitors()
        syncVisibleConsumers()
    }

    func toggle() { expanded ? collapse() : open() }

    /// The island stays on screen, so only a manual resign takes its keyboard.
    /// While Brim stays the active app (its Settings window is open, for
    /// example), that clears just the panel's own flag: AppKit keeps the island
    /// as its key window, typing still lands there, and a later makeKey()
    /// changes nothing, so a reopened page gets no caret. The keyboard
    /// goes back to the app's frontmost regular window on this Space, as
    /// closing a window does.
    func resignPanelKey() {
        guard let panel else { return }
        panel.resignKey()
        guard NSApp.keyWindow === panel,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let next = NSApp.orderedWindows.first(where: {
                  $0 !== panel && $0.isVisible && $0.isOnActiveSpace && $0.canBecomeMain
              })
        else { return }
        next.makeKey()
    }

    @discardableResult
    func showClipboard(toggle: Bool = false) -> Bool {
        guard acceptsUserInteraction, NotchSupport.routesClipboardWindow() else { return false }
        if toggle, expanded, selected == .clipboard, !showingAppPanel, !showingSections { collapse() }
        else { open(.clipboard) }
        return true
    }

    func hover(_ entered: Bool) {
        guard running, !suspended, !hiddenAtRestInFullscreen || watchesHiddenHover else { removeHoverExitMonitors(); return }
        let point = NSEvent.mouseLocation
        let wasInside = inside
        let showedPicker = showsCompactActivityPicker
        inside = watchesHiddenHover ? geometry.contains(point, in: geometry.collapsed)
            && windowHost?.isConcealedForMissionControl == false
            : windowHost?.containsHover(point) == true || pointerOverChildWindow(point)
        hoverState.update(pointerInside: inside)
        // A full hover opening goes straight from its resting size to the page.
        // The activity picker replaces that opening and keeps its hover response.
        let opensOnHover = hoverOpeningEnabled
            && UserDefaults.standard.bool(forKey: DefaultsKey.notchHoverExpands) && !showsCompactActivityPicker
        let emphasize = inside && !hiddenInFullscreen && !hiddenUntilHover && !expanded && !peeking
            && notice == nil && !opensOnHover
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if hoverEmphasized != emphasize || showedPicker != showsCompactActivityPicker {
            hoverEmphasized = emphasize
            refreshPresentation()
        }
        defer { syncHoverExitMonitoring(entered: entered, point: point) }
        guard !pinned, !keepsWorkingSurface else {
            hoverWork?.cancel(); hoverWork = nil
            return
        }
        // Overlapping tracking areas can report the same presence repeatedly.
        // Keep the first deadline until the pointer actually crosses the boundary.
        if inside == wasInside, let hoverWork, !hoverWork.isCancelled { return }
        hoverWork?.cancel(); hoverWork = nil
        // The visible choices replace automatic opening while several
        // activities compete. Clicking the strip still opens its full page.
        if showsCompactActivityPicker { return }
        if inside {
            guard !hoverState.suppressed, (notice == nil || hiddenUntilHover), !expanded, !peeking,
                  hoverOpeningEnabled else { return }
            if !hiddenInFullscreen, compactActivity != nil, compactActivityGeometry.compactActivityWingWidth > 0,
               !UserDefaults.standard.bool(forKey: DefaultsKey.notchHoverExpands) { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverWork = nil
                // An opening that is no longer eligible keeps any following:
                // an emphasis or a picker may still show, and the next move
                // decides whether it is still needed.
                guard self.running, !self.suspended, self.inside, !self.hoverState.suppressed,
                      !self.expanded, !self.peeking, !self.pinned, !self.keepsWorkingSurface,
                      !self.showsCompactActivityPicker,
                      (self.notice == nil || self.hiddenUntilHover),
                      self.hoverOpeningEnabled,
                      self.windowHost?.blocksHoverReveal() == false,
                      self.geometry.contains(NSEvent.mouseLocation, in: self.watchesHiddenHover ? self.geometry.collapsed : self.surfaceSize) else { return }
                // Following the closed island ends as it opens or peeks.
                self.removeHoverExitMonitors()
                if UserDefaults.standard.bool(forKey: DefaultsKey.notchHoverExpands) {
                    self.open(takeFocus: false)
                } else {
                    self.mutatePresentation(transitionContent: .reveal) { self.peeking = true }
                    self.provideHapticFeedback()
                }
            }
            hoverWork = work
            let delay = NotchSupport.sanitizedHoverDelay(UserDefaults.standard.double(forKey: DefaultsKey.notchHoverDelay))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else if NotchSupport.closesOnPointerExit(expanded: expanded, peeking: peeking, openedByHover: openedByHover) {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverWork = nil
                guard self.running, !self.suspended, !self.inside,
                      self.windowHost?.containsHover(NSEvent.mouseLocation) != true,
                      !self.pointerOverChildWindow(NSEvent.mouseLocation) else { return }
                guard !self.pinned, !self.keepsWorkingSurface,
                      !AssistiveKeyboard.ownsCocoaPoint(NSEvent.mouseLocation),
                      NotchSupport.closesOnPointerExit(expanded: self.expanded, peeking: self.peeking, openedByHover: self.openedByHover) else { return }
                self.collapse()
            }
            hoverWork = work
            let delay = NotchSupport.closeDelay()
            DispatchQueue.main.asyncAfter(deadline: .now() + (expanded ? delay : 0.12), execute: work)
        }
    }

    /// AppKit reports hover from the mouse moves it receives, and those can
    /// stop while the pointer crosses the transparent margin around the
    /// floating controls. One can even carry another window's coordinates.
    /// An exit can then arrive with the pointer still in that margin and be
    /// the last report. From such an exit until AppKit reports the pointer
    /// again, every move is checked here, so leaving still closes the island.
    /// The closed island's hover emphasis has the same gap, and worse: a fast
    /// pass up through the top edge to a display above can report its exit
    /// while the pointer still touches the island, or no exit at all. So while
    /// the emphasis shows or hover waits for an opening or reentry after an
    /// explicit close, moves are followed. A pointer at rest costs nothing.
    private func syncHoverExitMonitoring(entered: Bool, point: CGPoint) {
        let followsClosedHover = inside && !expanded && !peeking && notice == nil
            && (hoverWork?.isCancelled == false
                || hoverState.suppressed && hoverOpeningEnabled)
        let watching = (hoverEmphasized || followsClosedHover
                || !entered && NotchSupport.closesOnPointerExit(expanded: expanded, peeking: peeking, openedByHover: openedByHover))
            && !pinned && !hiddenUntilHover && !keepsWorkingSurface
            // Once watching, a pointer that leaves and slips back unreported is still seen.
            && (!hoverExitMonitors.isEmpty || windowHost?.containsHover(point) == true)
        guard watching else { removeHoverExitMonitors(); return }
        guard hoverExitMonitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.hover(false)
        }) { hoverExitMonitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.hover(false)
            return event
        }) { hoverExitMonitors.append(token) }
    }

    private func removeHoverExitMonitors() {
        hoverExitMonitors.forEach(NSEvent.removeMonitor)
        hoverExitMonitors.removeAll()
    }

    private func syncNoticeWithPreferences() {
        guard let notice, !NotchSupport.routes(notice.event) else { return }
        dismissNotice()
    }

    private func scheduleNoticeDismissal(after duration: TimeInterval) {
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissNotice() }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    var filteredSections: [NotchModule] {
        NotchSupport.filteredModules(modules, query: sectionQuery) { module in
            [module.title(L10n.shared.language), module.rawValue].joined(separator: " ")
        }
    }

    func searchSections(_ query: String) {
        guard sectionQuery != query else { return }
        mutatePresentation {
            sectionQuery = query
            highlightedSection = filteredSections.first
        }
    }

    func toggleSections() {
        if showingSections {
            open(appPanel: showingAppPanel, metric: selectedMetric)
        } else {
            sectionQuery = ""
            // The gallery opens from its top, stepping only as far as the
            // current section's row.
            sectionRow = 0
            highlightedSection = selected
            open(appPanel: showingAppPanel, metric: selectedMetric, sections: true)
        }
    }

    private var sectionRowLimits: (rows: Int, visible: Int) {
        let count = filteredSections.count
        return (NotchSectionPaging.rows(count: count, columns: geometry.sectionColumns), geometry.sectionRows(count: count))
    }

    /// Keyboard moves and search results keep the highlighted tile's row in
    /// view, moving the gallery no further than that row needs.
    private func revealHighlightedSection() {
        guard let target = highlightedSection, let index = filteredSections.firstIndex(of: target) else { return }
        let limits = sectionRowLimits
        let row = NotchSectionPaging.revealing(row: index / max(1, geometry.sectionColumns), first: sectionRow,
                                               rows: limits.rows, visible: limits.visible)
        if row != sectionRow { sectionRow = row }
    }

    /// Rest the gallery on `row`, within the rows it has.
    func showSectionRow(_ row: Int) {
        let limits = sectionRowLimits
        let next = NotchSectionPaging.clamped(row, rows: limits.rows, visible: limits.visible)
        guard next != sectionRow else { return }
        sectionRow = next
        provideHapticFeedback()
    }

    func scrollSections(by rows: Int) { showSectionRow(sectionRow + rows) }

    private func handleSectionKey(_ event: NSEvent) -> Bool {
        guard showingSections,
              (panel?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            highlightedSection = NotchSupport.adjacentModule(to: highlightedSection, modules: filteredSections,
                                                             backwards: modifiers == .shift)
            return true
        }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let target = highlightedSection, filteredSections.contains(target) { select(target) }
            return true
        }
        let direction: QuickToolsSupport.GridDirection
        switch event.keyCode {
        case 123 where sectionQuery.isEmpty: direction = .left
        case 124 where sectionQuery.isEmpty: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: return false
        }
        let sections = filteredSections
        guard !sections.isEmpty else { return true }
        // While typing, the side arrows keep editing the query and the
        // vertical pair steps through the matches in order.
        guard sectionQuery.isEmpty else {
            highlightedSection = NotchSupport.adjacentModule(to: highlightedSection, modules: sections,
                                                             backwards: direction == .up)
            return true
        }
        let index = highlightedSection.flatMap { sections.firstIndex(of: $0) } ?? 0
        highlightedSection = sections[QuickToolsSupport.gridIndex(after: index, count: sections.count,
                                                                   columns: geometry.sectionColumns,
                                                                   direction: direction)]
        return true
    }

    private func handleClipboardPasteKey(_ event: NSEvent) -> Bool {
        guard selected == .clipboard, !showingAppPanel, !showingSections, selectedMetric == nil else { return false }
        let commandOnly = event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
        guard let index = NotchClipboardPastePress.index(keyCode: event.keyCode, commandOnly: commandOnly)
        else { return false }
        clipboardPastePress = NotchClipboardPastePress(serial: (clipboardPastePress?.serial ?? 0) &+ 1, index: index)
        return true
    }

    func activateQuickAction(_ action: NotchQuickAction) {
        guard NotchSupport.isEnabled(), action.isAvailable() else { return }
        switch action {
        case .explore: toggleSections()
        case .settings: openSettings()
        case .pin: pinned.toggle()
        case .module(let module): select(module)
        case .control(let item):
            switch item {
            case .keepAwake: KeepAwakeManager.shared.toggle()
            case .speedTest: showMetric(.network)
            case .panel: openAppPanel()
            }
        }
    }

    func select(_ module: NotchModule) {
        guard modules.contains(module) else { return }
        open(module)
    }

    func openAppPanel(toggle: Bool = false) {
        if toggle, expanded, showingAppPanel, !showingSections { collapse(); return }
        MenuPanelFocus.shared.showNormalPanel()
        open(.controls, appPanel: true)
        // The toggling route is the menu bar's. Opened from there, the panel
        // has nothing behind it and closes on Escape, like the menu panel.
        if toggle { detailHasPage = false }
    }

    func showMetric(_ metric: MetricDetailKind, toggle: Bool = false) {
        guard metricIsAvailable(metric) else { return }
        if toggle, expanded, selectedMetric == metric, !showingSections { collapse(); return }
        open(.system, metric: metric)
        // A metric opened from its menu bar item closes on Escape, like the popover.
        if toggle { detailHasPage = false }
    }

    /// Fan Control is a single card, so its detail fits the card instead of
    /// opening a tall, mostly empty page. A taller card still scrolls in it.
    func updateFanDetailHeight(_ height: CGFloat) {
        guard expanded, selectedMetric == .fan, !showingAppPanel, !showingSections,
              height.isFinite, height > 0 else { return }
        let measured = ceil(height)
        guard fanDetailHeight != measured else { return }
        fanDetailHeight = measured
        refreshPresentation()
    }

    func goBack() {
        let changesPresentation = selectedMetric != nil || showingAppPanel
        mutatePresentation(transitionContent: changesPresentation ? .replace : .none) { selectedMetric = nil; showingAppPanel = false }
        syncVisibleConsumers()
        if changesPresentation { provideHapticFeedback() }
    }

    /// Escape steps back one level: a detail returns to its page as the Back
    /// button does, a page closes the layer it shows, and the island closes
    /// once nothing lies behind.
    private func stepBack() {
        if showingAppPanel || selectedMetric != nil {
            if detailHasPage { goBack() } else { collapse() }
        } else if let close = pageLayers[selected] {
            close()
        } else {
            collapse()
        }
    }

    /// A page reports the layer it shows over its content with how to close
    /// it, and nil once the layer or the page is gone.
    func setPageLayer(_ module: NotchModule, close: (() -> Void)?) {
        pageLayers[module] = close
    }

    func provideHapticFeedback() {
        guard acceptsUserInteraction, panel?.isVisible == true, NotchSupport.usesHapticFeedback() else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    private func missionControlDidRestore() {
        hover(windowHost?.containsHover(NSEvent.mouseLocation) == true)
        // A pointer that crossed displays during Mission Control is followed now.
        schedulePointerFollow()
    }

    func openSettings() {
        openSettings(showing: nil)
    }

    func openSettings(showing module: NotchModule?) {
        collapse()
        let destination = module.map { FeatureSettingsDestination(notch: .module($0)) }
        SettingsRouter.shared.request(destination ?? FeatureSettingsDestination(.notch))
        (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
    }

    func perform(_ action: @escaping () -> Void) {
        collapse()
        if let windowHost { windowHost.whenSettled(action) }
        else { DispatchQueue.main.async(execute: action) }
    }

    @discardableResult
    func show(_ incoming: NotchNotice) -> Bool {
        guard showsSystemFeedback, NotchSupport.routes(incoming.event),
              NotchSupport.shouldReplace(notice?.event, with: incoming.event) else { return false }
        noticeWork?.cancel(); noticeWork = nil
        // Key bursts only replace the displayed value. They never restart a
        // window resize or enqueue another layout animation.
        let transition: NotchContentTransition = !noticeCanPresent ? .none
            : notice == nil ? .reveal : notice?.event != incoming.event ? .replace : .none
        // The same notice with a new reading only fits its width, steadily.
        noticeFitsInPlace = noticeCanPresent && notice?.event == incoming.event
        mutatePresentation(transitionContent: transition) { notice = incoming }
        scheduleNoticeDismissal(after: incoming.event.duration)
        return true
    }

    /// The strip keeps its outgoing button until another notice or page takes its place.
    var stripNotice: NotchNotice? {
        notice ?? (expanded || peeking ? nil : departingNotice)
    }

    func activateNotice(_ selectedNotice: NotchNotice, fromEdgePress: Bool = false) {
        guard acceptsSystemFeedback, noticeCanPresent, NotchSupport.routes(selectedNotice.event) else { return }
        let shown = stripNotice
        guard shown?.clickTarget == selectedNotice.clickTarget
            || (fromEdgePress && shown == nil) else { return }
        open(selectedNotice.event == .clipboard ? .clipboard : selectedNotice.event == .agents ? .agents : .controls)
        // The notice grows into the page it led to, and stays gone after it closes.
        if expanded, (notice ?? departingNotice)?.clickTarget == selectedNotice.clickTarget { dismissNotice() }
    }

    private func dismissNotice() {
        noticeWork?.cancel(); noticeWork = nil
        endDeparture()
        let transition: NotchContentTransition = notice == nil || !noticeCanPresent ? .none : .depart
        let departing = transition == .depart ? notice : nil
        mutatePresentation(transitionContent: transition) {
            departingNotice = departing
            notice = nil
        }
        guard departingNotice != nil else { return }
        // Without motion the host hides the content at once; so does the view.
        guard windowHost?.departsContent == true else { endDeparture(restoringClicks: true); return }
        let work = DispatchWorkItem { [weak self] in self?.endDeparture(restoringClicks: true) }
        departureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMotion.departureHidden, execute: work)
    }

    private func endDeparture(restoringClicks: Bool = false) {
        departureWork?.cancel(); departureWork = nil
        guard departingNotice != nil else { return }
        departingNotice = nil
        windowHost?.finishDeparture()
        if restoringClicks { refreshPresentation() }
    }

    private var noticeCanPresent: Bool {
        !expanded
    }

    private func mutatePresentation(transitionContent: NotchContentTransition = .none, _ change: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
        refreshPresentation(transitionContent: transitionContent)
    }

    func refreshPresentation(animated: Bool = true, transitionContent: NotchContentTransition = .none) {
        // A notice with a new reading fits its new width in place.
        let fitsInPlace = noticeFitsInPlace && notice != nil
        noticeFitsInPlace = false
        activitySelection.reconcile(available: compactActivities)
        syncHiddenHoverMonitoring()
        // Closing, or a notice ending, can leave the island at rest away from
        // a pointer that has not moved since; it follows it then. The copies
        // on other displays follow what it shows closed.
        defer {
            schedulePointerFollow()
            syncMirrors()
        }
        if hiddenUntilHover {
            windowHost?.hide(animated: animated, transitionContent: transitionContent)
            removeScreenEdgeClickMonitors()
            return
        }
        let open = expanded || peeking || notice != nil
        guard open || (!hiddenAtRestInFullscreen && (geometry.isNotched || geometry.compactSideRoom != nil)) else {
            windowHost?.hide(animated: animated, transitionContent: transitionContent)
            removeScreenEdgeClickMonitors()
            return
        }
        let access = NotchQuickAccessConfiguration.current()
        let size = surfaceSize
        // A simulated cutout yields to the menu bar when it reappears in full screen.
        panel?.level = hiddenInFullscreen && !geometry.isNotched && !NotchSupport.coversMenus()
            ? NotchPanel.fullscreenLevel : NotchPanel.normalLevel
        // Preferences can change computed dimensions without publishing a
        // service property. Update SwiftUI's layout along with the native host.
        if let windowHost, windowHost.targetSize != size { objectWillChange.send() }
        windowHost?.setOutline(enabled: !fullscreenCompact && UserDefaults.standard.bool(forKey: DefaultsKey.notchOutlineEnabled))
        var presented = expanded ? expandedGeometry : geometry
        presented.surfaceShift = surfaceShift
        windowHost?.present(size: size, geometry: presented, animated: animated,
                            transitionContent: transitionContent,
                            quickAccess: expanded && !access.buttons.isEmpty
                                ? access : nil,
                            revealFromHidden: !hiddenInFullscreen
                                && (revealingFromAppFullscreen
                                    || UserDefaults.standard.bool(forKey: DefaultsKey.notchHideUntilHover)
                                    && UserDefaults.standard.bool(forKey: DefaultsKey.notchOpenOnHover)),
                            usesGlass: !fullscreenCompact && usesGlassSurface,
                            steady: fitsInPlace)
        // Closing can shrink the island away from a pointer that has not moved,
        // with no boundary crossing to report it. Only a pointer still over the
        // island may keep its next approach from opening it.
        if windowHost?.containsHover(NSEvent.mouseLocation) != true { hoverState.update(pointerInside: false) }
        let activationRect: CGRect
        if stripNotice != nil {
            activationRect = .zero
        } else if showsCompactActivityPicker {
            let strip = compactActivityGeometry.compactActivitySize
            activationRect = compactActivityGeometry.activationArea(
                in: strip, hasHeader: false, compactActivity: true)
                .offsetBy(dx: (size.width - strip.width) / 2, dy: 0)
        } else {
            activationRect = (expanded ? expandedGeometry : compactActivityIsVisible ? compactActivityGeometry : geometry)
                .activationArea(in: size, hasHeader: expanded || peeking, compactActivity: compactActivityIsVisible, expandedHeader: expanded)
                // Over the camera, wherever a strip reaching to one side puts it.
                .offsetBy(dx: -surfaceShift, dy: 0)
        }
        let text = FeatureStrings.notch(L10n.shared.language)
        windowHost?.setActivationArea(activationRect, title: expanded ? text.collapse : text.open,
            willPress: { [weak self] in
                guard let self else { return }
                self.hoverWork?.cancel()
                self.hoverState.close(pointerInside: true)
            }, activate: { [weak self] in self?.toggle() })
        // A move between displays brings the window back on the next turn, once
        // what it shows has been drawn for the display it landed on. Ordering
        // it in here would flash the shape it had on the display it left.
        if panel?.isVisible != true, mirrorHeldForArrival == nil { panel?.orderFrontRegardless() }
        syncScreenEdgeClicks()
    }

    private func syncHiddenHoverMonitoring() {
        if fullscreenCompact, !hoverOpeningEnabled {
            hoverWork?.cancel(); hoverWork = nil
            removeHoverExitMonitors()
        }
        guard running, !suspended, watchesHiddenHover, windowHost != nil else {
            removeHiddenHoverMonitors()
            return
        }
        guard hiddenHoverMonitors.isEmpty else { return }
        // The window is ordered out, so native tracking areas cannot see entry.
        // Observe movement without intercepting the menu bar or polling at rest.
        if let token = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.hover(true)
        }) { hiddenHoverMonitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.hover(true)
            return event
        }) { hiddenHoverMonitors.append(token) }
    }

    private func removeHiddenHoverMonitors() {
        hiddenHoverMonitors.forEach(NSEvent.removeMonitor)
        hiddenHoverMonitors.removeAll()
    }

    /// Movement is watched only while the island can follow the pointer to
    /// another display, and each event only checks whether it left the
    /// island's display; nothing polls at rest.
    private func syncPointerFollowing() {
        guard running, !suspended, followsPointer, windowHost != nil, NSScreen.screens.count > 1 else {
            removePointerMonitors()
            return
        }
        guard pointerMonitors.isEmpty else { return }
        // A drag moves the pointer without mouse-moved events.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.schedulePointerFollow()
        }) { pointerMonitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.schedulePointerFollow()
            return event
        }) { pointerMonitors.append(token) }
    }

    private func removePointerMonitors() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        pointerFollowWork?.cancel(); pointerFollowWork = nil
    }

    /// Only a closed island moves; an open page or a notice stays where it is.
    private var canFollowPointer: Bool {
        !expanded && !peeking && notice == nil && !keepsWorkingSurface
    }

    private func schedulePointerFollow() {
        guard followsPointer, windowHost != nil else { return }
        guard !NSMouseInRect(NSEvent.mouseLocation, geometry.screen, false) else {
            pointerFollowWork?.cancel(); pointerFollowWork = nil
            return
        }
        guard pointerFollowWork == nil, canFollowPointer else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pointerFollowWork = nil
            // A closing island finishes on the display it closed on.
            self.windowHost?.whenSettled { [weak self] in self?.followPointer() }
        }
        pointerFollowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pointerFollowDelay, execute: work)
    }

    private func followPointer() {
        // Mission Control spans the displays; the island moves once it is back.
        guard running, !suspended, followsPointer, canFollowPointer,
              windowHost?.isConcealedForMissionControl == false,
              let screen = NSScreen.withMouse, screen.displayID != displayID else { return }
        move(to: screen)
    }

    private func move(to screen: NSScreen) {
        guard let host = windowHost else { return }
        let destination = screen.displayID
        // On screen now: a copy has to be underneath before this window leaves,
        // or the display it leaves blinks empty, and the window server would
        // stretch it across to the display the pointer entered.
        let reveal = host.canRelocateOnScreen()
        relocationTicket += 1
        let ticket = relocationTicket
        displayID = destination
        mirrorHeldForArrival = reveal ? destination : nil
        if reveal {
            // Keep the copy on the display being entered until this window is
            // drawn for it. The copy on the display being left goes underneath.
            syncMirrors()
            guard relocationTicket == ticket, windowHost === host else { return }
            _ = host.orderOutForRelocation()
        }
        guard relocationTicket == ticket, windowHost === host else { return }
        updateScreen()
        guard relocationTicket == ticket, windowHost === host else { return }
        // Preferences or a disconnected display may choose a different screen.
        if reveal { mirrorHeldForArrival = displayID }
        // The menu space measured so far belongs to the display it left.
        invalidateMenuSpace()
        syncVisibleConsumers()
        refreshPresentation(animated: false)
        guard reveal, relocationTicket == ticket, windowHost === host else { return }
        let arrival = displayID
        // SwiftUI draws the new display's shape at the end of this turn, while
        // the window is still out. It comes back on the next one, over the copy.
        let work = DispatchWorkItem { [weak self, weak host] in
            guard let self, let host, self.relocationTicket == ticket, self.windowHost === host else { return }
            guard self.running, !self.suspended else {
                self.cancelRelocation()
                host.hide(animated: false)
                host.cancelRelocation()
                self.syncMirrors()
                return
            }
            // A screen can disappear before its debounced notification runs.
            // Settle on the currently selected screen, or let teardown cancel us.
            let missing = !NSScreen.screens.contains { $0.displayID == self.displayID }
            if missing {
                self.updateScreen()
                guard self.relocationTicket == ticket, self.windowHost === host else { return }
                self.invalidateMenuSpace()
                self.syncVisibleConsumers()
            }
            if missing || self.displayID != arrival {
                self.mirrorHeldForArrival = self.displayID
                self.refreshPresentation(animated: false)
                guard self.relocationTicket == ticket, self.windowHost === host else { return }
            }
            host.orderFrontForRelocation()
            guard self.relocationTicket == ticket, self.windowHost === host else { return }
            self.mirrorHeldForArrival = nil
            self.syncMirrors()
            guard self.relocationTicket == ticket, self.windowHost === host else { return }
            self.syncScreenEdgeClicks()
        }
        DispatchQueue.main.async(execute: work)
    }

    private func cancelRelocation() {
        relocationTicket += 1
        mirrorHeldForArrival = nil
    }

    // MARK: Every display

    /// The closed island as another display draws it, in a window of its own.
    private struct NotchMirror {
        let host: NotchWindowHost
        let model: NotchMirrorModel
    }

    /// With the island on every display, it follows the pointer as it does
    /// when it only follows it, and each other display shows a copy of what
    /// it shows closed. The copies are drawn for their own displays, a
    /// capsule or a notch, and they take no part in hovering or notices.
    private func syncMirrors() {
        guard showsOnAllDisplays, running, !suspended, windowHost != nil else { closeMirrors(); return }
        let screens = NSScreen.screens
        for (id, mirror) in mirrors where !screens.contains(where: { $0.displayID == id }) {
            mirror.host.close()
            mirrors[id] = nil
            mirrorsHiddenByApp.remove(id)
        }
        let activity = compactActivity
        // An island hidden until the pointer reaches it hides its copies as
        // well, unless it shows the activity they would draw.
        let hidesAtRest = NotchSupport.hidesUntilHover() && (activity == nil || !NotchSupport.hiddenShowsActivity())
        let outline = UserDefaults.standard.bool(forKey: DefaultsKey.notchOutlineEnabled)
        for screen in screens {
            let id = screen.displayID
            var base: NotchGeometry?
            if id != displayID || id == mirrorHeldForArrival, !hidesAtRest, !fullscreenDisplays.contains(id) {
                var geometry = baseGeometry(for: screen)
                geometry.compactSideRoom = mirrorSideRoom(on: screen, geometry: geometry)
                // A simulated island needs the menus' room at rest, as the island does.
                if geometry.isNotched || geometry.compactSideRoom != nil {
                    // Keep the arriving copy only while it may still show.
                    // Fullscreen and hide-until-hover must also hide a held copy.
                    if id == mirrorHeldForArrival { continue }
                    base = geometry
                }
            }
            guard let base else {
                // A full-screen Space already slides the screen, so only an app's
                // own full screen eases its copy away.
                let byApp = id != displayID && fullscreenDisplays.contains(id) && !fullscreenSpaceDisplays.contains(id)
                if !byApp { mirrorsHiddenByApp.remove(id) }
                if let mirror = mirrors[id] {
                    if byApp { mirrorsHiddenByApp.insert(id) }
                    if mirror.model.shown {
                        mirror.model.shown = false
                        mirror.host.hide(animated: byApp)
                    }
                }
                continue
            }
            let (strip, size) = mirrorSurface(on: base, activity: activity)
            let mirror = mirrors[id] ?? makeMirror(geometry: base, size: size)
            mirrors[id] = mirror
            if mirror.model.outline != outline {
                mirror.model.outline = outline
                mirror.host.setOutline(enabled: outline)
            }
            let sharing: NSWindow.SharingType = NotchSupport.showsInCaptures() ? .readOnly : .none
            if mirror.host.panel.sharingType != sharing { mirror.host.panel.sharingType = sharing }
            let revealing = !mirror.model.shown
            // Where an app's full screen eased the copy away, it eases back in.
            let afterApp = revealing && mirrorsHiddenByApp.remove(id) != nil
            let previous = mirror.model.activity
            guard mirror.model.update(geometry: base, strip: strip, size: size, activity: activity) || revealing else { continue }
            mirror.model.shown = true
            // Shown at once where the island just left, so the two trade places.
            mirror.host.present(size: size, geometry: base, animated: !revealing || afterApp,
                                transitionContent: !revealing && previous != activity ? .replace : .none,
                                revealFromHidden: afterApp)
            mirror.host.setActivationArea(CGRect(origin: .zero, size: size),
                                          title: FeatureStrings.notch(L10n.shared.language).open,
                                          willPress: {}, activate: { [weak self] in self?.bringIsland(to: id) })
            guard !mirror.host.panel.isVisible else { continue }
            // Under the window that is about to leave, so that display keeps
            // an island when the window goes. In front, the copy would cover
            // it and the two would blink as they traded.
            if mirrorHeldForArrival != nil, let live = windowHost?.panel, live.isVisible, live.windowNumber > 0 {
                mirror.host.panel.order(.below, relativeTo: live.windowNumber)
            } else {
                mirror.host.panel.orderFrontRegardless()
            }
        }
    }

    /// A copy's closed surface: the strip of what the island shows, drawn
    /// for that display, or the island at rest there.
    private func mirrorSurface(on base: NotchGeometry, activity: NotchCompactActivity?) -> (strip: NotchGeometry, size: CGSize) {
        guard let activity else {
            return (base, base.restingSize(showsContent: !base.floats && idleContent != .none))
        }
        if base.floats { return (base, capsuleStripSize(for: activity, geometry: base)) }
        let strip = compactGeometry(for: activity, base: base)
        return (strip, strip.compactActivitySize)
    }

    /// Another display's menus are never measured. A copy covers them when
    /// the island may, or where there are none, and otherwise gives way.
    private func mirrorSideRoom(on screen: NSScreen, geometry: NotchGeometry) -> CGFloat? {
        let hasMenuBar = NSScreen.screensHaveSeparateSpaces || NSScreen.withMenuBar == screen
        guard NotchSupport.coversMenus() || !hasMenuBar else { return nil }
        return NotchMenuBarLayout.sideRoom(screen: geometry.screen, cameraWidth: geometry.cameraWidth,
                                           barHeight: geometry.menuBarHeight, occupied: [])
    }

    private func makeMirror(geometry: NotchGeometry, size: CGSize) -> NotchMirror {
        let model = NotchMirrorModel(geometry: geometry, size: size)
        let host = NotchWindowHost(content: AnyView(NotchMirrorView(service: self, mirror: model)),
                                   geometry: geometry, size: size,
                                   background: { AnyView(NotchWindowBackground(presentation: $0)) })
        host.panel.title = FeatureStrings.notch(L10n.shared.language).title
        return NotchMirror(host: host, model: model)
    }

    private func closeMirrors() {
        guard !mirrors.isEmpty else { return }
        mirrors.values.forEach { $0.host.close() }
        mirrors.removeAll()
        mirrorsHiddenByApp.removeAll()
    }

    /// Only the copies ask which displays are in full screen, and only when
    /// the island hides there; the island asks for its own display.
    private func updateFullscreenDisplays() {
        guard showsOnAllDisplays, UserDefaults.standard.bool(forKey: DefaultsKey.notchHideInFullscreen)
        else { fullscreenDisplays = []; fullscreenSpaceDisplays = []; return }
        let covered = NotchAppFullscreen.coveredDisplays()
        guard let topology = SpaceWindowBridge.topology() else {
            fullscreenDisplays = covered
            fullscreenSpaceDisplays = []
            return
        }
        let separate = NSScreen.screensHaveSeparateSpaces
        let displays = NSScreen.screens.map(\.displayID)
        fullscreenSpaceDisplays = Set(displays.filter { topology.isFullscreen(on: $0, separateSpaces: separate) })
        fullscreenDisplays = Set(displays.filter { fullscreenSpaceDisplays.contains($0) || covered.contains($0) })
    }

    /// A click on a copy brings the island to its display, open, closing it
    /// on the display it was open on.
    private func bringIsland(to id: CGDirectDisplayID) {
        guard running, !suspended, showsOnAllDisplays, id != displayID else { return }
        if expanded || peeking { collapse() }
        windowHost?.whenSettled { [weak self] in
            guard let self, self.running, !self.suspended, self.canFollowPointer,
                  let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
            self.move(to: screen)
            self.open()
        }
    }

    private var screenEdgeClickArea: CGRect? {
        // A notice takes these clicks as well.
        guard running, !suspended, !expanded,
              let panel, panel.isVisible, !panel.ignoresMouseEvents else { return nil }
        let geometry = compactActivityIsVisible ? compactActivityGeometry : self.geometry
        // A notice can be visible even when a menu occupies the simulated cutout.
        guard geometry.isNotched || geometry.compactSideRoom != nil else { return nil }
        var size = surfaceSize
        if geometry.floats { size.width = min(size.width, NotchCapsuleLayout.availableWidth(geometry)) }
        // The menu bar still gets these clicks, so beside a camera a notice
        // leaves the items under its wings alone, as an activity's strip does.
        let area = geometry.activationArea(in: size, hasHeader: peeking,
                                           compactActivity: compactActivityIsVisible || stripNotice != nil)
        guard !area.isEmpty else { return nil }
        let frame = geometry.frame(for: size)
        return CGRect(x: frame.minX + area.minX, y: frame.maxY - area.maxY, width: area.width, height: area.height)
    }

    private func syncScreenEdgeClicks() {
        guard screenEdgeClickArea != nil else { removeScreenEdgeClickMonitors(); return }
        if let original = screenEdgePress?.notice, let shown = stripNotice, original.clickTarget != shown.clickTarget {
            screenEdgePress = nil
        }
        guard screenEdgeClickMonitors.isEmpty else { return }
        // The menu bar owns the first screen row even above its window level.
        // Observe only mouse clicks, with no event tap or Accessibility requirement.
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handleScreenEdgeEvent(event)
        }) { screenEdgeClickMonitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handleScreenEdgeEvent(event)
            return event
        }) { screenEdgeClickMonitors.append(token) }
    }

    private func handleScreenEdgeEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown || screenEdgePress != nil else { return }
        guard let location = event.cgEvent?.location, let primary = NSScreen.withMenuBar else {
            screenEdgePress = nil
            return
        }
        handleScreenEdgeClick(event.type, at: CGPoint(x: location.x, y: primary.frame.maxY - location.y),
                              isNotchWindow: event.window === panel)
    }

    private func handleScreenEdgeClick(_ type: NSEvent.EventType, at point: CGPoint, isNotchWindow: Bool) {
        guard let area = screenEdgeClickArea else { screenEdgePress = nil; return }
        let local = CGPoint(x: point.x - area.minX, y: area.maxY - point.y)
        switch type {
        case .leftMouseDown:
            screenEdgePress = nil
            // The menu bar a capsule leaves above itself takes its clicks too.
            guard !isNotchWindow, !keepsWorkingSurface,
                  CGRect(x: 0, y: 0, width: area.width, height: 1 + (geometry.floatingGap ?? 0)).contains(local),
                  windowHost?.containsDestination(point) == true else { return }
            screenEdgePress = (area, point, stripNotice)
            hoverWork?.cancel(); hoverWork = nil
            hoverState.close(pointerInside: true)
        case .leftMouseUp:
            let press = screenEdgePress
            screenEdgePress = nil
            // Keep the original action through expiry. A notice arriving under a
            // resting press still leaves its wings to the menu bar.
            guard let press, !keepsWorkingSurface else { return }
            if geometry.floats, press.notice != nil, notice == nil, point == press.point {
                // The capsule may have shrunk away from a stationary click.
                // The original point was hit-tested and must still be clear of menus.
                let free = CGSize(width: NotchCapsuleLayout.availableWidth(geometry), height: geometry.stripHeight)
                guard geometry.contains(point, in: free) else { return }
            } else {
                guard NotchSupport.screenEdgeArea(area, contains: point)
                        || (stripNotice == nil && NotchSupport.screenEdgeArea(press.area, contains: point)),
                      windowHost?.containsDestination(point) == true else { return }
            }
            if let original = press.notice { activateNotice(original, fromEdgePress: true) } else { open() }
        case .leftMouseDragged:
            // A press at the screen's edge reports a drag at once, often without
            // moving. Only a drag that leaves the island cancels the click.
            guard !NotchSupport.screenEdgeArea(area, contains: point),
                  !(screenEdgePress.map { NotchSupport.screenEdgeArea($0.area, contains: point) } ?? false) else { return }
            screenEdgePress = nil
        default:
            break
        }
    }

    private func removeScreenEdgeClickMonitors() {
        screenEdgeClickMonitors.forEach(NSEvent.removeMonitor)
        screenEdgeClickMonitors.removeAll()
        screenEdgePress = nil
    }

    private func stopMenuSpaceMonitoring() {
        menuSpaceTimer?.invalidate()
        menuSpaceTimer = nil
        menuSpaceGeneration += 1
    }

    /// Displays that share Spaces show the menu bar on the main one only.
    private var displayHasMenuBar: Bool {
        NSScreen.screensHaveSeparateSpaces || NSScreen.withMenuBar?.frame == geometry.screen
    }

    private func syncMenuSpaceMonitoring() {
        guard !hiddenInFullscreen else { stopMenuSpaceMonitoring(); return }
        // The explicit cover-menus choice also keeps a simulated island at
        // rest. Otherwise its visibility follows AX menu measurements, which
        // can change just because focus moves to another app or display.
        // A display without a menu bar, beside the main one when displays
        // share Spaces, has no menus to leave room for either.
        if running, !suspended, NotchSupport.coversMenus() || !displayHasMenuBar {
            // Nothing to measure: the island keeps the room an empty bar
            // would leave it, over whatever menus and status items are there.
            stopMenuSpaceMonitoring()
            applyMenuSpace(NotchMenuBarLayout.sideRoom(screen: geometry.screen, cameraWidth: geometry.cameraWidth,
                                                       barHeight: geometry.menuBarHeight, occupied: []))
            return
        }
        guard AXIsProcessTrusted() else {
            stopMenuSpaceMonitoring()
            if geometry.compactSideRoom != nil {
                geometry.compactSideRoom = nil
                refreshPresentation(animated: false)
            }
            return
        }
        // An island hidden until it shows activity measures on, to have its
        // room when one comes.
        let wanted = running && !suspended && (!hiddenUntilHover || NotchSupport.hiddenShowsActivity())
            && !expanded
            && (idleContent != .none || compactActivity != nil || !geometry.isNotched)
        guard wanted else { stopMenuSpaceMonitoring(); return }
        guard menuSpaceTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.readMenuSpace() }
        timer.tolerance = 0.2
        menuSpaceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        readMenuSpace()
    }

    private func invalidateMenuSpace() {
        menuSpaceGeneration += 1
        // Keep the last measured layout until its replacement arrives, so a
        // switch does not blink; the read that follows withdraws the cutout
        // once the new menu bar reaches the camera.
        readMenuSpace()
    }

    private func screenParametersDidChange() {
        guard running, !suspended else { return }
        screenRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenRefreshWork = nil
            guard self.running, !self.suspended else { return }
            self.invalidateMenuSpace()
            self.syncWithPreferences()
        }
        screenRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func readMenuSpace() {
        // The displayed menus belong to the menu bar's owner, which is not the
        // frontmost application while an accessory app such as a launcher has
        // focus; that app's own menu geometry was never laid out. When our own
        // Settings has focus, the menu owner can briefly be nil.
        guard menuSpaceTimer != nil, !menuSpaceReading,
              let pid = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
                ?? (NSApp.isActive ? getpid() : nil) else { return }
        menuSpaceReading = true
        let generation = menuSpaceGeneration
        let geometry = geometry
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? geometry.screen.maxY
        let window = panel?.windowNumber ?? -1
        menuSpaceQueue.async { [weak self] in
            let room = NotchMenuBarSpace.measure(pid: pid, geometry: geometry,
                                                primaryTop: primaryTop, ownWindow: window)
            DispatchQueue.main.async {
                guard let self else { return }
                self.menuSpaceReading = false
                guard self.menuSpaceTimer != nil else { return }
                guard self.menuSpaceGeneration == generation,
                      (NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
                        ?? (NSApp.isActive ? getpid() : nil)) == pid else {
                    self.readMenuSpace(); return
                }
                self.applyMenuSpace(room)
            }
        }
    }

    private func applyMenuSpace(_ room: CGFloat?) {
        guard geometry.compactSideRoom != room else { return }
        let previousSize = surfaceSize
        let grows = (room ?? 0) > (geometry.compactSideRoom ?? 0)
        geometry.compactSideRoom = room
        // Losing a safe center must also hide an unchanged bare cutout.
        if previousSize != surfaceSize || panel?.isVisible != true || room == nil {
            refreshPresentation(animated: grows)
        } else { syncScreenEdgeClicks() }
    }

    /// Only a laptop reports its lid, and only a laptop can lose its
    /// built-in screen while it keeps running.
    private static let hasLid = LidDisplayDimmer.lidClosed() != nil

    private var displayPreference: NotchDisplay {
        NotchDisplay(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.notchDisplay) ?? "") ?? .automatic
    }

    /// The displays as the choice of display reads them: which are built in,
    /// which have a camera housing, and which one has the menu bar.
    private static func displayLayout(_ screens: [NSScreen]) -> (builtIn: [Bool], notched: [Bool], main: Int) {
        (screens.map { CGDisplayIsBuiltin($0.displayID) != 0 },
         screens.map { $0.safeAreaInsets.top > 0 },
         screens.firstIndex(where: { $0 === NSScreen.withMenuBar }) ?? 0)
    }

    private func screenIndex(in screens: [NSScreen]) -> Int? {
        let preference = displayPreference
        var pointer: Int?
        if preference == .pointer || preference == .all {
            // The island stays on its display until it can follow the pointer.
            let mouse = NSEvent.mouseLocation
            pointer = screens.firstIndex { $0.displayID == displayID }
                ?? screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) }
        }
        let layout = Self.displayLayout(screens)
        return NotchSupport.screenIndex(preference: preference, builtIn: layout.builtIn, notched: layout.notched,
                                        main: layout.main, pointer: pointer, hasLid: Self.hasLid)
    }

    /// Whether `preference` lets the island reach a connected display without
    /// a notch, so the shape chosen for those displays shows somewhere.
    static func reachesDisplayWithoutNotch(_ preference: NotchDisplay) -> Bool {
        let layout = displayLayout(NSScreen.screens)
        return NotchSupport.reachesDisplayWithoutNotch(preference: preference, builtIn: layout.builtIn,
                                                       notched: layout.notched, main: layout.main, hasLid: hasLid)
    }

    /// With the chosen display away, as the built-in one with the lid closed,
    /// nothing keeps working for an island that cannot show.
    private func withdrawFromMissingScreen() {
        tearDownPresentation()
    }

    private func updateScreen() {
        let screens = NSScreen.screens
        menuBarMeasurements.retainDisplays(screens.map(\.displayID))
        guard let index = screenIndex(in: screens) else { withdrawFromMissingScreen(); return }
        let screen = screens[index]
        displayID = screen.displayID
        var next = baseGeometry(for: screen)
        let sameMenuBar = next.hasSameMenuBar(as: geometry)
        if sameMenuBar { next.compactSideRoom = geometry.compactSideRoom }
        let access = NotchQuickAccessConfiguration.current()
        next.quickAccessBottomInset = access.hasBottom ? NotchQuickAccessLayout.gutter : 0
        // Read with the floating buttons rather than on every layout pass,
        // which would decode them each time.
        next.sectionsButtonInRow = !access.actions.contains(.explore)
        if next != geometry { menuSpaceGeneration += 1; geometry = next }
        // A new camera or bar, such as a notch fit being adjusted, measures the
        // menus again at once rather than leaving the wings off until the timer.
        if !sameMenuBar { readMenuSpace() }
        if windowHost == nil {
            windowHost = NotchWindowHost(content: AnyView(NotchView(service: self)), geometry: geometry, size: surfaceSize,
                                        background: { AnyView(NotchWindowBackground(presentation: $0)) },
                                        quickAccess: { AnyView(NotchQuickAccessView(service: self, motion: $0, backdrop: $1)) })
            windowHost?.missionControlDidRestore = { [weak self] in self?.missionControlDidRestore() }
            windowHost?.setHoverHandler { [weak self] in self?.hover($0) }
            panel?.title = FeatureStrings.notch(L10n.shared.language).title
        }
        panel?.sharingType = NotchSupport.showsInCaptures() ? .readOnly : .none
        updateFullscreenVisibility(displayID: screen.displayID)
    }

    /// The island's geometry on a display, before its menus are measured.
    private func baseGeometry(for screen: NSScreen) -> NotchGeometry {
        let cameraWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            cameraWidth = max(0, right.minX - left.maxX)
        } else { cameraWidth = 0 }
        return NotchGeometry(screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                             cameraWidth: cameraWidth,
                             layout: NotchSize(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.notchSize) ?? "") ?? .spacious,
                             menuBarHeight: menuBarMeasurements.height(
                                displayID: screen.displayID, frame: screen.frame,
                                visibleTop: screen.visibleFrame.maxY, scale: screen.backingScaleFactor,
                                statusBarThickness: NSStatusBar.system.thickness),
                             customWidth: UserDefaults.standard.double(forKey: DefaultsKey.notchCustomWidth),
                             customHeight: UserDefaults.standard.double(forKey: DefaultsKey.notchCustomHeight),
                             cameraFit: NotchCameraFit.current(), silhouette: NotchSilhouette.current(),
                             capsuleFit: NotchCapsuleFit.current(),
                             hideMenuBarGap: UserDefaults.standard.bool(forKey: DefaultsKey.notchHideMenuBarGap),
                             outline: UserDefaults.standard.bool(forKey: DefaultsKey.notchOutlineEnabled),
                             barEdge: 1 / max(1, screen.backingScaleFactor))
    }

    private func updateFullscreenVisibility(displayID: CGDirectDisplayID) {
        // A game's own full screen leaves the desktop Space in place, so the
        // frontmost app's windows are read when the Space is not full screen.
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKey.notchHideInFullscreen)
        let bySpace = enabled
            && SpaceWindowBridge.topology()?.isFullscreen(on: displayID, separateSpaces: NSScreen.screensHaveSeparateSpaces) == true
        let hidden = bySpace || (enabled && NotchAppFullscreen.coveredDisplays().contains(displayID))
        hiddenByFullscreenSpace = bySpace
        guard hidden != hiddenInFullscreen else { return }
        hiddenInFullscreen = hidden
        if hidden {
            hoverWork?.cancel(); hoverWork = nil
            hoverEmphasized = false
            noticeWork?.cancel(); noticeWork = nil
            endDeparture()
            notice = nil
            collapse()
        }
    }

    private func fullscreenEnvironmentDidChange() {
        // Only the opt-in option depends on Spaces and the active app.
        guard running, !suspended,
              hiddenInFullscreen || UserDefaults.standard.bool(forKey: DefaultsKey.notchHideInFullscreen)
        else { return }
        let wasHidden = hiddenInFullscreen
        let wasBySpace = hiddenByFullscreenSpace
        updateScreen()
        // Each copy follows full screen on its own display.
        updateFullscreenDisplays()
        syncMirrors()
        // An unchanged state must not cut short a transition on screen, such
        // as the island closing after a click in another app.
        guard hiddenInFullscreen != wasHidden else { return }
        syncVisibleConsumers()
        // A full-screen Space already slides the screen, so the island hides and
        // returns at once there. An app's own full screen changes nothing else
        // on screen, so the island eases away and back as it does at any hide.
        let bySpace = wasBySpace || hiddenByFullscreenSpace
        revealingFromAppFullscreen = !bySpace && !hiddenInFullscreen
        refreshPresentation(animated: !bySpace)
        revealingFromAppFullscreen = false
    }

    /// A game can enter or leave its own full screen while it stays
    /// frontmost, with no Space or app change to announce it. A light poll
    /// follows that only while the island hides in full screen.
    private func syncAppFullscreenMonitoring() {
        guard running, !suspended, UserDefaults.standard.bool(forKey: DefaultsKey.notchHideInFullscreen) else {
            stopAppFullscreenMonitoring()
            return
        }
        appFullscreenDisplays = NotchAppFullscreen.coveredDisplays()
        guard appFullscreenTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.readAppFullscreen() }
        timer.tolerance = 0.3
        appFullscreenTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAppFullscreenMonitoring() {
        appFullscreenTimer?.invalidate()
        appFullscreenTimer = nil
        appFullscreenDisplays = []
    }

    /// Only a change reevaluates the island, so a steady game costs one
    /// window list read per second.
    private func readAppFullscreen() {
        let covered = NotchAppFullscreen.coveredDisplays()
        guard covered != appFullscreenDisplays else { return }
        appFullscreenDisplays = covered
        fullscreenEnvironmentDidChange()
    }

    private func installObservers() {
        observe(.default, NSMenu.didBeginTrackingNotification) { [weak self] in
            guard let self else { return }
            self.trackingMenu = true
            self.hoverWork?.cancel()
        }
        observe(.default, NSMenu.didEndTrackingNotification) { [weak self] in
            guard let self else { return }
            self.trackingMenu = false
            self.hover(self.windowHost?.contains(NSEvent.mouseLocation) == true)
            self.refreshPresentation()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.screenParametersDidChange()
        }
        observe(.default, UserDefaults.didChangeNotification) { [weak self] in
            self?.schedulePreferenceSync()
        }
        observe(.default, .menuPanelWillShow) { [weak self] in self?.collapse() }
        observe(.default, NSWindow.didBecomeKeyNotification) { [weak self] in self?.syncPanelKey() }
        observe(.default, NSWindow.didResignKeyNotification) { [weak self] in self?.syncPanelKey() }
        session.onConsole = SessionActivity.shared.isActive
        session.locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.schedulePreferenceSync()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.fullscreenEnvironmentDidChange()
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.applicationDidActivate() }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.updateSession { $0.sleeping = true }
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            // Sleep ends a screen saver even when its stop goes unannounced.
            self?.updateSession { $0.sleeping = false; $0.screenSaverRunning = false }
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.updateSession { $0.displaysSleeping = true }
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.updateSession { $0.displaysSleeping = false }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.updateSession { $0.onConsole = false }
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.updateSession { $0.onConsole = true }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.updateSession { $0.locked = true }
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            // No screen saver outlasts an unlock, whether or not its stop was announced.
            self?.updateSession { $0.locked = false; $0.screenSaverRunning = false }
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { [weak self] in
            self?.updateSession { $0.screenSaverRunning = true }
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { [weak self] in
            self?.updateSession { $0.screenSaverRunning = false }
        }
    }

    /// AppStorage can notify during drawing. A preference import or a group
    /// of edits only needs one deferred pass over the final saved settings.
    private func schedulePreferenceSync() {
        guard running, preferenceSyncWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.preferenceSyncWork = nil
            guard self.running else { return }
            self.syncWithPreferences()
        }
        preferenceSyncWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func applicationDidActivate() {
        guard !suspended else { return }
        fullscreenEnvironmentDidChange()
        invalidateMenuSpace()
        let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard identifier != Bundle.main.bundleIdentifier, identifier != AssistiveKeyboard.bundleID else { return }
        panel?.resignKey()
        if expanded, modules.contains(.clipboard) { ClipboardHistoryService.shared.rememberPasteTarget() }
        if expanded, !pinned, !keepsWorkingSurface,
           NotchSupport.closesOnActivation(openedByHover: openedByHover, clicked: clickedSinceOpening,
                                           pointerInside: windowHost?.containsHover(NSEvent.mouseLocation) == true) {
            collapse()
        }
    }

    private func syncPanelKey() {
        let isKey = panel?.isKeyWindow == true
        if panelIsKey != isKey { panelIsKey = isKey }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, token))
    }

    private func updateSession(_ change: (inout NotchSessionState) -> Void) {
        guard running else { return }
        let couldPresent = session.canPresent
        let wasLocked = session.locked
        change(&session)
        // An unlock is someone at the Mac, even when the display's wake is
        // announced after it.
        if session.locked != wasLocked, session.locked ? session.hearsLockChange : session.onConsole,
           NotchLockScreenSupport.playsSounds() {
            NotchLockScreenService.shared.playSound(locking: session.locked)
        }
        // The lock screen starts leaving before the island comes back, since
        // rebuilding the island holds the main thread for a moment. It stops
        // none of the sources an island that returns takes back.
        if wasLocked, !session.locked { NotchLockScreenService.shared.sync(session) }
        if couldPresent != session.canPresent {
            if session.canPresent {
                syncWithPreferences()
            } else {
                tearDownPresentation()
            }
        }
        // After the island's own teardown or return: what the lock screen
        // starts is not stopped under it, and what the island takes back is
        // not stopped as the lock screen leaves.
        NotchLockScreenService.shared.sync(session)
    }

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        clickedSinceOpening = false
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.clickedElsewhere()
        }) { eventMonitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            // Opening by pointer may assign a control focus automatically.
            // Restore its visible indicator before handling any keyboard input.
            if event.type == .keyDown, event.window === self.panel, !self.showsKeyboardFocus {
                self.showsKeyboardFocus = true
            }
            // While an input method is composing, Esc belongs to it and
            // drops the candidate; the island takes the next one.
            if event.type == .keyDown, event.window === self.panel, event.keyCode == 53,
               (self.panel?.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            if event.type == .keyDown, event.window === self.panel {
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
                    self.toggleSections()
                    return nil
                }
                // The island has no settings button of its own: Command-Comma
                // opens its page in Settings, as an app's own settings do.
                if modifiers == .command, event.charactersIgnoringModifiers == "," {
                    self.openSettings()
                    return nil
                }
                if modifiers == [.command, .option],
                   let module = NotchSupport.moduleShortcut(event.charactersIgnoringModifiers ?? "", modules: self.modules) {
                    self.select(module)
                    return nil
                }
                if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift],
                   let module = NotchSupport.adjacentModule(to: self.selected, modules: self.modules,
                                                           backwards: modifiers.contains(.shift)) {
                    self.select(module)
                    return nil
                }
                if event.keyCode == 53, self.showingSections {
                    self.toggleSections()
                    return nil
                }
                if self.handleSectionKey(event) { return nil }
                if self.handleClipboardPasteKey(event) { return nil }
            }
            if event.type == .keyDown, event.window === self.panel, event.keyCode == 53 {
                self.stepBack()
                return nil
            }
            let click = clicks.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue))
            let islandWindow = self.ownsWindow(event.window)
            if click, islandWindow { self.clickedSinceOpening = true }
            if click, !islandWindow { self.clickedElsewhere() }
            return event
        }) { eventMonitors.append(token) }
    }

    private func clickedElsewhere() {
        guard !keepsSurfaceOnClick,
              windowHost?.contains(NSEvent.mouseLocation) != true,
              !mirrors.values.contains(where: { $0.model.shown && $0.host.contains(NSEvent.mouseLocation) }),
              (NSApp.delegate as? AppDelegate)?.isOverStatusItem(NSEvent.mouseLocation) != true,
              !AssistiveKeyboard.ownsCocoaPoint(NSEvent.mouseLocation) else { return }
        collapse()
    }

    /// The panel and what hangs from it: a SwiftUI popover opened in the
    /// island is a child window, so a click in it is not a click away.
    private func ownsWindow(_ window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        return sequence(first: window, next: { $0.parent }).contains { $0 === panel }
    }

    private func pointerOverChildWindow(_ point: CGPoint) -> Bool {
        panel?.childWindows?.contains { $0.isVisible && $0.frame.contains(point) } == true
    }

    private func handleSectionScroll(_ event: NSEvent) -> Bool {
        guard running, !suspended, expanded, showingSections, let panel, !trackingMenu,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            sectionScroll = NotchSectionScroll()
            return false
        }
        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        // The header scrolls nothing; the tiles and the rest of the body step rows.
        guard windowHost?.containsSurface(screenPoint) == true,
              panel.frame.maxY - screenPoint.y > expandedGeometry.headerTopInset + expandedGeometry.headerRowHeight else {
            sectionScroll = NotchSectionScroll()
            return false
        }
        let steps = sectionScroll.steps(deltaY: Double(event.scrollingDeltaY), timestamp: event.timestamp,
                                        precise: event.hasPreciseScrollingDeltas, hasPhase: !event.phase.isEmpty,
                                        began: event.phase.contains(.began),
                                        ended: !event.phase.intersection([.ended, .cancelled]).isEmpty,
                                        momentum: !event.momentumPhase.isEmpty)
        if steps != 0 { scrollSections(by: steps) }
        return true
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    private func bindEvents() {
        subscriptions.removeAll()
        if modules.contains(.system), AppFeature.fanControl.isAvailable {
            // The fan card only exists once the page's first sample lands; the
            // strip that was sized without it reserves its row again.
            SystemMonitor.shared.$snapshot.map { $0.fanSpeeds.isEmpty }.removeDuplicates().dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.expanded, self.selected == .system, self.selectedMetric == nil,
                          !self.showingAppPanel, !self.showingSections else { return }
                    self.refreshPresentation()
                }.store(in: &subscriptions)
        }
        if modules.contains(.agents) {
            // Only what changes the island's size or strip: a turn starting or
            // ending, the first read landing, which agents have cards, and
            // which are working, since each one's mark widens the strip.
            AgentUsageService.shared.$snapshot
                .map { ($0.loaded, $0.live.isEmpty, $0.seen, Set($0.live.map(\.provider))) }
                .removeDuplicates(by: ==)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.syncMenuSpaceMonitoring()
                    self?.objectWillChange.send()
                    self?.refreshPresentation()
                }.store(in: &subscriptions)
            // An added or removed Codex account adds or removes a card.
            CodexProfileLimitsService.shared.$states
                .map { $0.map(\.id) }
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.selected == .agents else { return }
                    self.objectWillChange.send()
                    self.refreshPresentation()
                }.store(in: &subscriptions)
        }
        if NotchKeepAwakeSupport.showsActivity() {
            // A session starting or ending, or its end moving, which can
            // change the reading and the wings it needs.
            let awake = KeepAwakeManager.shared
            awake.$isActive.combineLatest(awake.$endDate).removeDuplicates { $0 == $1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.syncMenuSpaceMonitoring()
                    self?.objectWillChange.send()
                    self?.refreshPresentation()
                }.store(in: &subscriptions)
        }
        if NotchSupport.routes(.agents) {
            AgentUsageService.shared.events.receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.showAgentEvent($0) }
                .store(in: &subscriptions)
        }
        stopPower()
        if NotchSupport.routes(.inputSource) {
            // The layout labels already refresh on every source change and
            // post when they do, including once at launch; the current source
            // is read now so that first post announces nothing.
            inputSourceID = InputSourceSelection.currentReading()?.id
            NotificationCenter.default.publisher(for: GlobalShortcut.keyboardLayoutDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.inputSourceChanged() }
                .store(in: &subscriptions)
        }
        if NotchSupport.routes(.clipboard) {
            let history = ClipboardHistoryService.shared
            history.capturedEntry.receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                let text = FeatureStrings.clipboard(L10n.shared.language)
                self.show(NotchNotice(event: .clipboard, title: text.copied,
                                      detail: text.title, symbol: "doc.on.clipboard"))
            }.store(in: &subscriptions)
        }
        if NotchSupport.routes(.battery) || idleContent == .battery { startPower() }
    }

    private func showAgentEvent(_ event: AgentUsageEvent) {
        let text = FeatureStrings.notchAgents(L10n.shared.language)
        let locale = L10n.shared.language.formattingLocale()
        func window(_ window: AgentLimitWindow) -> String {
            switch window.kind {
            case .session: return text.session
            case .weekly: return window.scope.map { "\(text.weekly) · \($0)" } ?? text.weekly
            case .other: return window.minutes.map { AgentFormat.duration(TimeInterval($0) * 60, locale: locale, units: 1) }
                ?? text.readoutLimit
            }
        }
        switch event {
        case .finished(let provider, let duration, let cost, _, _):
            show(NotchNotice(event: .agents, title: text.finished(provider.displayName),
                             detail: [AgentFormat.duration(duration, locale: locale), cost > 0 ? AgentFormat.cost(cost) : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "),
                             symbol: provider.symbol, agent: provider))
        case .limitWarning(let provider, let limit):
            show(NotchNotice(event: .agents, title: "\(provider.displayName) · \(window(limit))",
                             detail: NotchAgentSupport.limitShare(limit, display: NotchAgentSupport.limitDisplay(),
                                                                  text: text),
                             symbol: "exclamationmark.triangle.fill", agent: provider))
        case .limitReset(let provider, let limit):
            show(NotchNotice(event: .agents, title: "\(provider.displayName) · \(window(limit))",
                             detail: text.limitRenewed, symbol: "arrow.clockwise", agent: provider))
        case .budgetReached(let spent, _):
            show(NotchNotice(event: .agents, title: text.budgetTitle, detail: AgentFormat.cost(spent),
                             symbol: "dollarsign.circle.fill"))
        }
    }

    private func inputSourceChanged() {
        guard let reading = InputSourceSelection.currentReading(), reading.id != inputSourceID else { return }
        inputSourceID = reading.id
        // The code takes the value's place and the source's own name stands
        // beside it.
        show(NotchNotice(event: .inputSource, title: reading.code, detail: reading.name, symbol: "keyboard"))
    }

    private func startPower() {
        guard PowerSampler.hasInternalBattery else { return }
        powerSampler = PowerSampler(smc: nil)
        power = powerSampler?.sample() ?? PowerReading()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let owner = Unmanaged<NotchService>.fromOpaque(context).takeUnretainedValue()
            owner.powerChanged()
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func stopPower() {
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        powerSource = nil
        powerSampler = nil
    }

    private func powerChanged() {
        guard running, !suspended, let sampler = powerSampler else { return }
        let before = power
        let next = sampler.sample()
        power = next
        let low = (next.chargePercent ?? 100) <= 20 && (before.chargePercent ?? 0) > 20
        guard before.externalConnected != next.externalConnected || low
                || (before.isCharging && !next.isCharging && next.chargePercent == 100) else { return }
        let text = FeatureStrings.notch(L10n.shared.language)
        let title = low ? text.lowBattery : next.externalConnected
            ? (next.isCharging ? text.charging : next.chargePercent == 100
                ? text.charged : L10n.shared.s.powerPluggedIn) : text.onBattery
        show(NotchNotice(event: .battery, title: title,
                         detail: next.chargePercent.map { "\($0)%" } ?? "",
                         symbol: next.externalConnected ? "battery.100percent.bolt" : "battery.25percent"))
    }

    private func syncVisibleConsumers() {
        syncMenuSpaceMonitoring()
        guard running, !suspended else { releaseMonitor(); return }
        if fullscreenCompact {
            releaseMonitor()
            return
        }
        let needs = expanded && selected == .system && selectedMetric == nil && modules.contains(.system) && !showingAppPanel
            && !showingSections
        var detailNeeds = expanded && !showingSections ? selectedMetric?.monitorNeeds ?? .none : .none
        if needs, AppFeature.monitorDisk.isAvailable { detailNeeds.disk = true }
        if needs, AppFeature.fanControl.isAvailable { detailNeeds.fanSpeed = true }
        if needs, AppFeature.connectedDevices.isAvailable { detailNeeds.connectedDevices = true }
        SystemMonitor.shared.setNotchDetailNeeds(detailNeeds)
        if needs != notchNeedsMonitor {
            notchNeedsMonitor = needs
            SystemMonitor.shared.setNotchVisible(needs)
        }
    }

    private func releaseMonitor() {
        SystemMonitor.shared.setNotchDetailNeeds(.none)
        guard notchNeedsMonitor else { return }
        notchNeedsMonitor = false
        SystemMonitor.shared.setNotchVisible(false)
    }
}
