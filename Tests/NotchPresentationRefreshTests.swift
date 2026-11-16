// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation
import Combine

/// The production refresh runs against a window double, without showing UI or
/// starting the island's hardware consumers. Shortcut changes model AppStorage:
/// they alter computed geometry without publishing a service property.
enum NotchPresentationRefreshContract {
    typealias DispatchQueue = NotchScreenRefreshContract.DispatchQueue
    enum NSEvent {
        static var mouseLocation = CGPoint.zero
        static var monitorRemovals = 0
        static func removeMonitor(_ token: Any) { monitorRemovals += 1 }
    }
    enum NSWorkspace {
        static var shared = Accessibility()
        struct Accessibility { var accessibilityDisplayShouldReduceMotion = false }
    }
    enum NotchPanel { static let normalLevel = 1, fullscreenLevel = 0 }
    enum UserDefaults {
        static var standard = Preferences()
        struct Preferences {
            var hides = false
            var outline = false
            var coversMenus = true
            func bool(forKey key: String) -> Bool {
                switch key {
                case DefaultsKey.notchHideUntilHover: return hides
                case DefaultsKey.notchOutlineEnabled: return outline
                default: return true
                }
            }
        }
    }
    enum NotchContentTransition { case none, reveal, dismiss, depart, replace }
    private static let layout = NotchNotice(event: .inputSource, title: "ABC", detail: "ABC", symbol: "keyboard")
    struct NotchQuickAccessConfiguration {
        let buttons: [Int] = []
        static func current() -> Self { Self() }
    }
    enum FeatureStrings {
        static func notch(_ language: Int) -> (collapse: String, open: String) { ("Close", "Open") }
    }
    enum L10n {
        static let shared = SelfValue()
        struct SelfValue { let language = 0 }
    }
    final class Panel {
        var isVisible = true
        var alphaValue: CGFloat = 1
        var ignoresMouseEvents = false, acceptsKeyFocus = true, acceptsMouseMovedEvents = false
        var attachedSheet: Bool?
        var level = 1, keyRequests = 0
        func makeKey() { keyRequests += 1 }
        func resignKey() {}
        func orderOut(_ sender: Any?) { isVisible = false }
        func orderFrontRegardless() { isVisible = true }
    }
    final class Host {
        let panel = Panel()
        var departsContent = false
        func finishDeparture() { departsContent = false }
        var concealedForMissionControl = false
        var isConcealedForMissionControl: Bool { concealedForMissionControl }
        var missionControlDidRestore: (() -> Void)?
        var missionControlAlpha: CGFloat = 1
        var missionControlMouseEvents = false
        var desktopReadings = 0
        var mouseEventsBeforeHide: Bool?
        var hidesWhenSettled = false
        var restoringFromMissionControl = false
        var fadeCompletion: (() -> Void)?
        func fadeMissionControl(to alpha: CGFloat, completion: (() -> Void)? = nil) {
            panel.alphaValue = alpha
            fadeCompletion = completion
        }
        func syncMissionControlMonitoring() {}
        var hideAnimations: [Bool] = []
        func hide(animated: Bool, transitionContent: NotchContentTransition = .none) {
            hideAnimations.append(animated)
            panel.orderOut(nil)
        }
        var targetSize: CGSize = .zero
        var frame: CGRect = .zero
        var animatingFrame: CGRect?
        var activationRect = CGRect.zero
        var willPress: (() -> Void)?
        var activate: (() -> Void)?
        func containsHover(_ point: CGPoint) -> Bool { !concealedForMissionControl && frame.contains(point) }
        func contains(_ point: CGPoint) -> Bool { !concealedForMissionControl && (animatingFrame ?? frame).contains(point) }
        var onPresent: ((CGSize) -> Void)?
        var usesGlass = false
        var revealFromHidden = false
        var steady = false
        var outlineEnabled = false
        var transitions: [NotchContentTransition] = []
        func setOutline(enabled: Bool) { outlineEnabled = enabled }
        func present(size: CGSize, geometry: NotchGeometry, animated: Bool,
                     transitionContent: NotchContentTransition, quickAccess: NotchQuickAccessConfiguration?,
                     revealFromHidden: Bool, usesGlass: Bool, steady: Bool) {
            transitions.append(transitionContent)
            self.steady = steady
            departsContent = transitionContent == .depart && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.usesGlass = usesGlass
            self.revealFromHidden = revealFromHidden
            onPresent?(size)
            targetSize = size
            frame = geometry.frame(for: size)
        }
        func setActivationArea(_ rect: CGRect, title: String, willPress: @escaping () -> Void, activate: @escaping () -> Void) {
            activationRect = rect
            self.willPress = willPress
            self.activate = activate
        }
    }
    class State: ObservableObject {
        var noticeFitsInPlace = false
        var activitySelection = NotchActivitySelection()
        var compactActivities: [NotchCompactActivity] = []
        var showsCompactActivityPicker = false
        var hiddenInFullscreen = false
        var revealingFromAppFullscreen = false
        /// Hidden until hover and set to show activity, as Settings has it.
        var hiddenShowsActivity = false
        var fullscreenCompact: Bool { hiddenInFullscreen && !expanded && !peeking }
        let objectWillChange = ObservableObjectPublisher()
        var running = true, suspended = false
        var shortcutCount = 4
        var selected = NotchModule.controls
        var pinned = false
        var showingSections = false
        var showingAppPanel = false
        var selectedMetric: Bool?
        var expanded = true
        var peeking = false, compactActivityIsVisible = false
        var compactActivityOverride: NotchCompactActivity?
        var compactActivity: NotchCompactActivity? {
            get { compactActivityOverride ?? (compactActivityIsVisible ? .keepAwake : nil) }
            set { compactActivityOverride = newValue }
        }
        var notice: NotchNotice?, departingNotice: NotchNotice?
        var noticeWork: DispatchWorkItem?, departureWork: DispatchWorkItem?
        var inside = false
        var hoverWork: DispatchWorkItem?
        var hoverState = NotchHoverState()
        var windowHost: Host? = Host()
        var panel: Panel? { windowHost?.panel }
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     safeAreaTop: 32, cameraWidth: 210)
        var expandedPageTop = NotchPageTop.row
        var modules = NotchModule.allCases
        var homeControls: [NotchControlItem] = []
        var expandedGeometry: NotchGeometry { geometry }
        var compactActivityGeometry: NotchGeometry { geometry.compactKeepAwakeGeometry() }
        var surfaceSize: CGSize {
            if fullscreenCompact { return geometry.restingSize(showsContent: false) }
            if !expanded, compactActivityIsVisible { return compactActivityGeometry.compactActivitySize }
            if !expanded { return geometry.collapsed }
            return expandedGeometry.expandedSize(module: selected, shortcutCount: shortcutCount)
        }
        var surfaceShift: CGFloat = 0
        func syncHiddenHoverMonitoring() {}
        func schedulePointerFollow() {}
        func syncMirrors() {}
        var mirrorHeldForArrival: CGDirectDisplayID?
        func toggle() { expanded.toggle() }
        func collapse() { expanded = false }
        var edgeClicksEnabled = false
        func syncScreenEdgeClicks() { edgeClicksEnabled = true }
        func removeScreenEdgeClickMonitors() { edgeClicksEnabled = false }
    }

    static func run(_ suite: TestSuite) {
        UserDefaults.standard.hides = false
        UserDefaults.standard.outline = false
        defer {
            UserDefaults.standard.hides = false
            UserDefaults.standard.outline = false
        }
        for reduceMotion in [false, true] {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = reduceMotion
            let service = Service()
            service.expanded = false
            service.notice = layout
            service.refreshPresentation()
            service.dismissNotice()
            if !reduceMotion {
                suite.expect(service.stripNotice == layout && service.windowHost?.activationRect == .zero,
                             "the outgoing notice button keeps clicks until its fade finishes")
                DispatchQueue.main.advance(NotchMotion.departureHidden)
            }
            suite.expect(service.stripNotice == nil && service.windowHost?.activationRect.isEmpty == false,
                         "the normal activation button returns when the outgoing notice leaves")
            service.windowHost?.activate?()
            suite.expect(service.expanded, "the restored native button opens the island")
        }
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = false
        let outlined = Service()
        outlined.expanded = false
        UserDefaults.standard.outline = true
        outlined.refreshPresentation(animated: false)
        suite.expect(outlined.windowHost?.outlineEnabled == true,
                     "the optional outline reaches the resting island")
        outlined.compactActivityIsVisible = true
        outlined.refreshPresentation(animated: false)
        suite.expect(outlined.windowHost?.outlineEnabled == true,
                     "the optional outline stays around a compact activity")
        UserDefaults.standard.outline = false
        outlined.refreshPresentation(animated: false)
        suite.expect(outlined.windowHost?.outlineEnabled == false,
                     "turning the outline off updates the existing island")
        let toolbar = Service()
        toolbar.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                          safeAreaTop: 32, cameraWidth: 210, layout: .spacious)
        suite.expect(toolbar.expandedGeometry.headerCameraGap == 210,
                     "a standard wide page puts its top row beside the camera")
        let page = Service()
        suite.expect(page.expandedGeometry.headerCameraGap == 210 && page.expandedGeometry.headerTopInset == 0
                     && page.expandedGeometry.pageTopInset == 36 + NotchLayout.spacing,
                     "a page's row wraps the camera wherever each side keeps its wing, and the page starts below it")
        let picker = Service()
        picker.expanded = false
        picker.compactActivityIsVisible = true
        picker.showsCompactActivityPicker = true
        picker.compactActivities = [.agents, .keepAwake]
        picker.activitySelection.select(.agents, available: picker.compactActivities)
        picker.refreshPresentation(animated: false)
        suite.expect(picker.windowHost!.activationRect.maxY
                     <= picker.compactActivityGeometry.compactActivitySize.height,
                     "the native open button never covers the activity choices below the strip")
        // An agent between turns leaves Keep Awake alone on the island for a moment.
        picker.compactActivities = [.keepAwake]
        picker.refreshPresentation(animated: false)
        suite.expect(picker.activitySelection.preferred == .agents
                     && picker.activitySelection.current(available: picker.compactActivities) == .keepAwake,
                     "production refresh keeps a chosen activity through a gap and shows what remains")
        picker.compactActivities = [.agents, .keepAwake]
        picker.refreshPresentation(animated: false)
        suite.expect(picker.activitySelection.current(available: picker.compactActivities) == .agents,
                     "the chosen activity comes back instead of Keep Awake")
        picker.compactActivities = []
        picker.refreshPresentation(animated: false)
        suite.expect(picker.activitySelection.preferred == nil,
                     "production refresh forgets the choice once nothing is left to show")
        let fullscreen = Service()
        fullscreen.pinned = true
        fullscreen.expanded = false
        fullscreen.compactActivityIsVisible = true
        fullscreen.hiddenInFullscreen = true
        fullscreen.refreshPresentation()
        suite.expect(fullscreen.panel?.isVisible == true && !fullscreen.acceptsSystemFeedback
                     && fullscreen.acceptsUserInteraction && fullscreen.panel?.level == NotchPanel.normalLevel
                     && fullscreen.edgeClicksEnabled && fullscreen.windowHost?.targetSize == fullscreen.geometry.restingSize(showsContent: false)
                     && fullscreen.windowHost?.activationRect.size == fullscreen.geometry.restingSize(showsContent: false),
                     "fullscreen keeps a black, clickable cutout without automatic feedback or activity wings")
        fullscreen.windowHost?.activate?()
        fullscreen.refreshPresentation()
        suite.expect(fullscreen.expanded && fullscreen.panel?.isVisible == true
                     && fullscreen.acceptsUserInteraction && !fullscreen.acceptsSystemFeedback
                     && fullscreen.windowHost?.targetSize == fullscreen.surfaceSize,
                     "clicking the fullscreen cutout opens the island")
        fullscreen.collapse()
        fullscreen.refreshPresentation()
        suite.expect(fullscreen.panel?.isVisible == true && fullscreen.windowHost?.targetSize == fullscreen.geometry.restingSize(showsContent: false),
                     "closing in fullscreen returns to the clickable black cutout")
        fullscreen.hiddenInFullscreen = false
        fullscreen.refreshPresentation()
        suite.expect(fullscreen.panel?.isVisible == true && fullscreen.acceptsSystemFeedback,
                     "leaving fullscreen restores ordinary content and feedback routing")
        let activity = Service()
        activity.expanded = false
        activity.compactActivityIsVisible = true
        activity.refreshPresentation(animated: false)
        activity.windowHost?.activate?()
        suite.expect(activity.expanded, "the camera beside an activity opens the island")
        activity.refreshPresentation(animated: false)
        activity.windowHost?.activate?()
        suite.expect(!activity.expanded, "the open island's close button still closes it while an activity runs")
        let fullscreenSimulated = Service()
        fullscreenSimulated.expanded = false
        fullscreenSimulated.geometry = NotchGeometry(screen: fullscreenSimulated.geometry.screen, safeAreaTop: 0, cameraWidth: 0,
                                                     compactSideRoom: 64)
        fullscreenSimulated.hiddenInFullscreen = true
        UserDefaults.standard.coversMenus = false
        fullscreenSimulated.refreshPresentation(animated: false)
        suite.expect(fullscreenSimulated.panel?.isVisible == false && !fullscreenSimulated.edgeClicksEnabled
                     && fullscreenSimulated.acceptsUserInteraction,
                     "a simulated cutout with no camera to cover stays out of full-screen content")
        fullscreenSimulated.expanded = true
        fullscreenSimulated.refreshPresentation(animated: false)
        suite.expect(fullscreenSimulated.panel?.isVisible == true
                     && fullscreenSimulated.panel?.level == NotchPanel.fullscreenLevel,
                     "a simulated island opened by a shortcut yields to the menu bar in fullscreen")
        fullscreenSimulated.collapse()
        fullscreenSimulated.refreshPresentation(animated: false)
        suite.expect(fullscreenSimulated.panel?.isVisible == false,
                     "closing a simulated island in fullscreen hides it again")
        fullscreenSimulated.expanded = true
        fullscreenSimulated.hiddenInFullscreen = false
        fullscreenSimulated.refreshPresentation(animated: false)
        suite.expect(fullscreenSimulated.panel?.level == NotchPanel.normalLevel,
                     "leaving fullscreen restores the usual panel level")
        UserDefaults.standard.coversMenus = true
        fullscreenSimulated.hiddenInFullscreen = true
        fullscreenSimulated.refreshPresentation(animated: false)
        suite.expect(fullscreenSimulated.panel?.level == NotchPanel.normalLevel,
                     "the explicit cover-menus preference keeps the usual panel level")
        let missionControl = Service()
        missionControl.windowHost?.concealedForMissionControl = true
        suite.expect(!missionControl.acceptsSystemFeedback && !missionControl.acceptsUserInteraction
                     && !missionControl.showsSystemFeedback,
                     "a concealed island leaves system feedback available to its other presenters")
        missionControl.windowHost?.concealedForMissionControl = false
        suite.expect(missionControl.acceptsSystemFeedback && missionControl.showsSystemFeedback,
                     "leaving Mission Control restores island feedback routing")

        let material = Service()
        material.expanded = false
        material.geometry = NotchGeometry(screen: material.geometry.screen, safeAreaTop: 38,
                                          cameraWidth: 210, compactSideRoom: 0)
        material.refreshPresentation(animated: false)
        suite.expect(!material.usesGlassSurface && material.windowHost?.usesGlass == false,
                     "compact presentation remains opaque regardless of camera or footer height")
        material.peeking = true
        material.refreshPresentation(animated: false)
        suite.expect(material.windowHost?.usesGlass == true, "peek requests the glass backdrop")
        material.peeking = false
        material.expanded = true
        material.refreshPresentation(animated: false)
        suite.expect(material.windowHost?.usesGlass == true, "expanded content requests the glass backdrop")

        let closing = Service()
        closing.refreshPresentation(animated: false)
        let open = closing.windowHost?.frame ?? .zero
        for (point, stillOver) in [(CGPoint(x: open.midX, y: open.minY + 4), false), (CGPoint(x: open.midX, y: open.maxY - 1), true)] {
            closing.expanded = true
            closing.refreshPresentation(animated: false)
            NSEvent.mouseLocation = point
            closing.hoverState.close(pointerInside: closing.windowHost?.containsHover(point) == true)
            closing.expanded = false
            closing.refreshPresentation()
            suite.expect(closing.hoverState.suppressed == stillOver, stillOver
                ? "a pointer still over the closed island keeps it from reopening until it leaves"
                : "closing away from a pointer that has not moved lets its next approach open the island")
        }
        NSEvent.mouseLocation = .zero

        let service = Service()
        var contentSize = service.surfaceSize
        service.windowHost?.targetSize = contentSize
        var invalidations = 0
        let subscription = service.objectWillChange.sink {
            invalidations += 1
            contentSize = service.surfaceSize
        }
        defer { subscription.cancel() }
        var mismatches = 0
        service.windowHost?.onPresent = { size in
            if contentSize != size { mismatches += 1 }
        }
        // Shortcuts that fit the same rows keep the island's height, so only
        // a change that resizes the island may publish.
        var resizes = 0
        let counts = [9, 4, 5, 12, 4, 9]
        for count in counts {
            let before = service.surfaceSize
            service.shortcutCount = count
            service.refreshPresentation(animated: false)
            if service.surfaceSize != before { resizes += 1 }
            suite.expect(contentSize == service.surfaceSize,
                   "changing the home page's shortcuts updates the content height without reopening the island")
        }
        suite.expect(mismatches == 0, "content is invalidated before the native window receives its new size")
        suite.expect(resizes > 0 && resizes < counts.count && invalidations == resizes,
               "each change with a new size publishes it, and one keeping the size stays quiet")
        for _ in 0..<1000 { service.refreshPresentation() }
        suite.expect(invalidations == resizes, "unchanged presentations do not repeatedly invalidate SwiftUI layout")


        let simulated = Service()
        simulated.expanded = false
        simulated.panel?.isVisible = false
        simulated.geometry = NotchGeometry(screen: CGRect(x: -1440, y: 900, width: 1440, height: 900),
                                          safeAreaTop: 0, cameraWidth: 0)
        simulated.refreshPresentation(animated: false)
        suite.expect(simulated.panel?.isVisible == false && !simulated.edgeClicksEnabled,
               "an unmeasured simulated cutout does not cover a menu or receive screen-edge clicks")
        simulated.applyMenuSpace(0)
        suite.expect(simulated.panel?.isVisible == true && simulated.edgeClicksEnabled
               && simulated.windowHost?.frame == simulated.geometry.frame(for: simulated.surfaceSize),
               "a confirmed free center can show the simulated cutout without side room")
        let bareSize = simulated.surfaceSize
        let occupied = [CGRect(x: simulated.geometry.screen.midX - 15, y: simulated.geometry.screen.maxY - 24,
                               width: 90, height: 24)]
        let blocked = NotchMenuBarLayout.sideRoom(screen: simulated.geometry.screen, cameraWidth: simulated.geometry.cameraWidth,
                                                 barHeight: simulated.geometry.menuBarHeight, occupied: occupied)
        suite.expect(blocked == nil, "a real center collision is distinct from zero-width free wings")
        simulated.applyMenuSpace(blocked)
        suite.expect(simulated.surfaceSize == bareSize && simulated.panel?.isVisible == false && !simulated.edgeClicksEnabled,
               "a center collision hides even an unchanged bare simulated cutout")
        for active in [false, true] {
            simulated.compactActivityIsVisible = active
            simulated.applyMenuSpace(64)
            suite.expect(simulated.panel?.isVisible == true && simulated.edgeClicksEnabled,
                   "free menu space restores idle and active simulated content")
            simulated.applyMenuSpace(nil)
            suite.expect(simulated.panel?.isVisible == false && !simulated.edgeClicksEnabled,
                   "idle and active simulated content both release menus when clearance is lost")
            simulated.refreshPresentation(animated: false)
            suite.expect(simulated.panel?.isVisible == false,
                   "a later refresh cannot redisplay compact activity over an occupied center")
        }
        simulated.expanded = true
        simulated.refreshPresentation()
        suite.expect(simulated.panel?.isVisible == true && simulated.windowHost?.frame.maxY == simulated.geometry.screen.maxY,
               "explicitly opening tools remains available without a menu measurement")
        suite.expect(simulated.windowHost?.revealFromHidden == false,
               "ordinary openings keep their existing presentation behavior")
        simulated.expanded = false
        simulated.refreshPresentation()
        suite.expect(simulated.windowHost?.hideAnimations.last == true,
               "closing an expanded island without safe menu space animates its withdrawal")
        suite.expect(simulated.panel?.isVisible == false,
               "closing tools withdraws their simulated cutout if the center is still unverified")
        simulated.expanded = true
        simulated.revealingFromAppFullscreen = true
        simulated.refreshPresentation()
        suite.expect(simulated.windowHost?.revealFromHidden == true,
               "an app's own full screen ending reveals the withdrawn island from the screen edge")
        simulated.revealingFromAppFullscreen = false
        simulated.expanded = false
        simulated.refreshPresentation()

        UserDefaults.standard.hides = true
        for isPhysical in [false, true] {
            let hidden = Service()
            if !isPhysical { hidden.geometry = simulated.geometry }
            hidden.expanded = false
            hidden.compactActivityIsVisible = true
            hidden.notice = layout
            hidden.refreshPresentation()
            suite.expect(hidden.panel?.isVisible == false && !hidden.edgeClicksEnabled && !hidden.showsSystemFeedback,
                   "hidden mode withdraws the entire window, including compact activity and an existing notice")
            suite.expect(hidden.windowHost?.hideAnimations.last == true,
                   "closing a hidden-until-hover island requests an animated withdrawal")
            hidden.refreshPresentation(animated: false)
            suite.expect(hidden.windowHost?.hideAnimations.last == false,
                   "a nonanimated refresh preserves immediate withdrawal")
            hidden.expanded = true
            hidden.refreshPresentation()
            suite.expect(hidden.panel?.isVisible == true && hidden.showsSystemFeedback, "explicit openings remain visible in hidden mode")
            suite.expect(hidden.windowHost?.revealFromHidden == true,
                   "opening a hidden island requests a reveal from the screen edge")
            hidden.expanded = false
            hidden.refreshPresentation()
            suite.expect(hidden.panel?.isVisible == false, "closing hides the window again")
        }
        // Set to show activity, the hidden island takes notices while it
        // waits, comes into view while an activity runs or a notice shows,
        // and hides again once it ends. Otherwise it stays out of sight.
        for showsActivity in [false, true] {
            let waiting = Service()
            waiting.hiddenShowsActivity = showsActivity
            waiting.expanded = false
            waiting.refreshPresentation()
            suite.expect(waiting.panel?.isVisible == false && waiting.showsSystemFeedback == showsActivity,
                   "a hidden island takes notices while it waits only when set to show activity")
            waiting.compactActivityIsVisible = true
            waiting.refreshPresentation()
            suite.expect(waiting.panel?.isVisible == showsActivity,
                   "an activity brings a hidden island into view only when it is set to show activity")
            waiting.compactActivityIsVisible = false
            waiting.refreshPresentation()
            suite.expect(waiting.panel?.isVisible == false, "a hidden island goes out of sight again once the activity ends")
            waiting.notice = layout
            waiting.refreshPresentation()
            suite.expect(waiting.panel?.isVisible == showsActivity,
                   "a notice brings a hidden island into view only when it is set to show activity")
            waiting.notice = nil
            waiting.refreshPresentation()
            suite.expect(waiting.panel?.isVisible == false, "a hidden island goes out of sight again once the notice ends")
        }
        // Beside a simulated cutout it draws the activity only once the menus
        // leave it room, and waits out of sight for the pointer again when
        // they take that room back.
        let roomless = Service()
        roomless.hiddenShowsActivity = true
        roomless.expanded = false
        roomless.geometry = NotchGeometry(screen: roomless.geometry.screen, safeAreaTop: 0, cameraWidth: 0)
        roomless.compactActivityIsVisible = true
        roomless.refreshPresentation()
        suite.expect(roomless.panel?.isVisible == false && roomless.hiddenUntilHover,
                     "with no room beside a simulated cutout, a hidden island set to show activity waits for the pointer")
        roomless.applyMenuSpace(64)
        suite.expect(roomless.panel?.isVisible == true && !roomless.hiddenUntilHover,
                     "room from the menus brings a waiting activity into view")
        roomless.applyMenuSpace(nil)
        suite.expect(roomless.panel?.isVisible == false && roomless.hiddenUntilHover,
                     "losing that room hides the activity and waits for the pointer again")
        UserDefaults.standard.hides = false
        let physical = Service()
        physical.expanded = false
        physical.compactActivityIsVisible = true
        physical.refreshPresentation(animated: false)
        suite.expect(physical.panel?.isVisible == true && !physical.compactActivityGeometry.compactActivityUsesFooter
               && physical.compactActivityGeometry.compactActivityWingWidth == 0
               && physical.windowHost?.targetSize.height == physical.geometry.menuBarHeight,
               "a compact activity on a physical camera retracts its wings and stays at menu-bar height without a menu measurement")
    }
}
