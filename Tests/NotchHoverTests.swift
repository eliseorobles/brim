// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Exercises the production hover handler with a controlled clock and pointer.
/// No input is posted and the user's preferences are never read or changed.
enum NotchHoverTests {
    typealias DispatchQueue = NotchScreenRefreshContract.DispatchQueue
    final class NSEvent {
        typealias EventTypeMask = AppKit.NSEvent.EventTypeMask
        static var mouseLocation = CGPoint.zero
        static var global: [Int: (NSEvent) -> Void] = [:]
        static var local: [Int: (NSEvent) -> NSEvent?] = [:]
        static var nextID = 0
        static func addGlobalMonitorForEvents(matching: EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
            nextID += 1; global[nextID] = handler; return nextID
        }
        static func addLocalMonitorForEvents(matching: EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
            nextID += 1; local[nextID] = handler; return nextID
        }
        static func removeMonitor(_ token: Any) { global[token as! Int] = nil; local[token as! Int] = nil }
    }
    enum UserDefaults {
        static var standard = Preferences()
        struct Preferences {
            var enabled = true, expands = true, hides = false, fullscreenHover = false
            var delay = NotchSupport.defaultHoverDelay
            var closeDelay = NotchSupport.defaultCloseDelay
            func bool(forKey key: String) -> Bool {
                switch key {
                case DefaultsKey.notchHideUntilHover: return hides
                case DefaultsKey.notchOpenOnHover: return enabled
                case DefaultsKey.notchHoverInFullscreen: return fullscreenHover
                default: return expands
                }
            }
            func double(forKey key: String) -> Double { delay }
        }
    }
    enum AssistiveKeyboard {
        static var active = false
        static func ownsCocoaPoint(_ point: CGPoint) -> Bool { active }
    }
    final class NSWorkspace {
        static let shared = NSWorkspace()
        var accessibilityDisplayShouldReduceMotion = false
    }
    final class Host {
        var visible = true
        var rect = CGRect.zero
        /// The floating controls' hover rects on screen, margin included.
        var controls: [CGRect] = []
        var departsContent = true
        func finishDeparture() { departsContent = false }
        var isConcealedForMissionControl = false
        var revealChecks = 0
        func blocksHoverReveal() -> Bool {
            revealChecks += 1
            return isConcealedForMissionControl
        }
        func containsHover(_ point: CGPoint) -> Bool {
            visible && !isConcealedForMissionControl && (CGRect(origin: .zero, size: rect.size)
                .contains(CGPoint(x: point.x - rect.minX, y: rect.maxY - point.y)) || controls.contains { $0.contains(point) })
        }
    }
    enum NotchContentTransition { case none, reveal, dismiss, depart, replace }
    class State {
        var noticeFitsInPlace = false
        func schedulePointerFollow() {}
        var hiddenInFullscreen = false
        var fullscreenCompact: Bool { hiddenInFullscreen && !expanded && !peeking }
        var showsSystemFeedback = true, routesNotices = true
        func routes(_ event: NotchEvent) -> Bool { routesNotices }
        /// Hidden until hover and set to show activity, as Settings has it.
        var hiddenShowsActivity = false
        var running = true, suspended = false, inside = false, hoverEmphasized = false
        var pinned = false, keepsWorkingSurface = false
        var expanded = false, peeking = false, openedByHover = false
        var notice: NotchNotice?
        var noticeWork: DispatchWorkItem?
        var departingNotice: NotchNotice?
        var departureWork: DispatchWorkItem?
        var compactActivity: NotchCompactActivity?
        var compactActivities: [NotchCompactActivity] = []
        var hoverState = NotchHoverState()
        var hiddenHoverMonitors: [Any] = []
        var hoverExitMonitors: [Any] = []
        var hoverWork: DispatchWorkItem?
        var childWindowFrames: [CGRect] = []
        func pointerOverChildWindow(_ point: CGPoint) -> Bool { childWindowFrames.contains { $0.contains(point) } }
        var windowHost: Host? = Host()
        var geometry = NotchGeometry(screen: CGRect(x: -1920, y: 900, width: 1920, height: 1080),
                                     safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 22, compactSideRoom: 64)
        var compactActivityGeometry: NotchGeometry {
            geometry.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.lowerBound)
        }
        var surfaceSize: CGSize {
            if fullscreenCompact { return geometry.restingSize(showsContent: false) }
            if let notice { return geometry.noticeSize(wings: notice.wings(in: geometry)) }
            if expanded { return geometry.expanded }
            if peeking { return geometry.peek }
            let resting = compactActivity == nil ? geometry.collapsed : compactActivityGeometry.compactActivitySize
            return hoverEmphasized ? NotchHoverEmphasis.size(from: resting, geometry: geometry) : resting
        }
        var openings = 0, closures = 0, feedbacks = 0
        var requestedModule: NotchModule?
        func open(_ module: NotchModule? = nil, takeFocus: Bool) {
            requestedModule = module
            openings += 1; expanded = true; openedByHover = !takeFocus
            hoverState.open(); hoverWork?.cancel(); hoverWork = nil
            updateBounds()
        }
        func collapse() {
            closures += 1; expanded = false; peeking = false; openedByHover = false
            hoverState.close(pointerInside: windowHost?.containsHover(NSEvent.mouseLocation) == true)
            hoverWork?.cancel(); hoverWork = nil
            updateBounds()
        }
        func mutatePresentation(transitionContent: NotchContentTransition, _ change: () -> Void) { change(); updateBounds() }
        var refreshes = 0, menuSpaceSyncs = 0
        func refreshPresentation() { refreshes += 1; updateBounds() }
        func syncMenuSpaceMonitoring() { menuSpaceSyncs += 1 }
        func provideHapticFeedback() { feedbacks += 1 }
        func updateBounds() { windowHost?.rect = geometry.frame(for: surfaceSize) }
    }

    static func run(_ suite: TestSuite) {
        func expect(_ condition: Bool, _ message: String) {
            suite.expect(condition, message)
        }
        let layout = NotchNotice(event: .inputSource, title: "ABC", detail: "ABC", symbol: "keyboard")
        func fixture(physical: Bool = false) -> Service {
            DispatchQueue.main = NotchScreenRefreshContract.Scheduler()
            UserDefaults.standard = UserDefaults.Preferences()
            // Each case starts with no observers left by a pointer an earlier case never moved.
            NSEvent.global = [:]
            NSEvent.local = [:]
            AssistiveKeyboard.active = false
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = false
            let service = Service()
            if physical {
                service.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                                 safeAreaTop: 32, cameraWidth: 180, compactSideRoom: 64)
            }
            service.updateBounds()
            NSEvent.mouseLocation = CGPoint(x: service.geometry.screen.midX, y: service.geometry.screen.maxY)
            return service
        }
        func leave(_ service: Service) {
            NSEvent.mouseLocation = CGPoint(x: service.geometry.screen.minX, y: service.geometry.screen.minY)
            service.hover(false)
        }
        for physical in [false, true] {
            for reduced in [false, true] {
                let picker = fixture(physical: physical)
                picker.compactActivity = .agents
                picker.compactActivities = [.agents, .keepAwake]
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = reduced
                picker.hover(true)
                suite.expect(picker.showsCompactActivityPicker && picker.hoverWork == nil,
                             "hover exposes named choices without an automatic opening deadline, including Reduce Motion")
                DispatchQueue.main.advance(2)
                suite.expect(picker.openings == 0, "the activity chooser stays available while the person decides")
                leave(picker)
                suite.expect(!picker.showsCompactActivityPicker, "leaving hides the activity chooser")
                picker.expanded = true
                picker.inside = true
                suite.expect(!picker.showsCompactActivityPicker, "the chooser does not cover an open page")
                picker.expanded = false
                picker.notice = layout
                suite.expect(!picker.showsCompactActivityPicker, "system notices retain priority")
                picker.notice = nil
                picker.hiddenInFullscreen = true
                suite.expect(!picker.showsCompactActivityPicker, "full-screen content hiding retains priority")
            }
        }
        for physical in [false, true] {
            let clickOnly = fixture(physical: physical)
            UserDefaults.standard.enabled = false
            let resting = clickOnly.surfaceSize
            clickOnly.hover(true)
            let emphasized = clickOnly.surfaceSize
            suite.expect(emphasized.height == resting.height + 5 && emphasized.width >= resting.width
                         && emphasized.width <= resting.width + 20 && clickOnly.hoverWork == nil,
                         "click-only islands pulse within available menu space without scheduling an opening")
            leave(clickOnly)
            suite.expect(clickOnly.surfaceSize == resting,
                         "leaving restores the resting island size")
        }
        let hiddenPulse = fixture()
        UserDefaults.standard.hides = true
        hiddenPulse.windowHost?.visible = false
        let hiddenResting = hiddenPulse.surfaceSize
        hiddenPulse.hover(true)
        suite.expect(hiddenPulse.surfaceSize == hiddenResting,
                     "an invisible island does not pulse before its hover reveal")
        let reducedMotion = fixture()
        UserDefaults.standard.enabled = false
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = true
        let reducedResting = reducedMotion.surfaceSize
        reducedMotion.hover(true)
        suite.expect(reducedMotion.surfaceSize == reducedResting,
                     "Reduce Motion leaves the resting island still on hover")
        for physical in [false, true] {
            for opensOnHover in [false, true] {
                let compactPulse = fixture(physical: physical)
                UserDefaults.standard.enabled = opensOnHover
                compactPulse.compactActivity = .keepAwake
                compactPulse.updateBounds()
                let compactResting = compactPulse.surfaceSize
                compactPulse.hover(true)
                suite.expect(compactPulse.surfaceSize.height == compactResting.height + (opensOnHover ? 0 : 5)
                             && compactPulse.hoverEmphasized == !opensOnHover,
                             "a compact activity waits at rest for a hover opening and pulses for a click opening")
                leave(compactPulse)
                suite.expect(compactPulse.surfaceSize == compactResting,
                             "the compact activity returns to its original size on exit")
            }
        }
        for physical in [false, true] {
            for hides in [false, true] {
                for expands in [false, true] {
                    let hiddenFullscreen = fixture(physical: physical)
                    UserDefaults.standard.hides = hides
                    UserDefaults.standard.expands = expands
                    hiddenFullscreen.hiddenInFullscreen = true
                    hiddenFullscreen.windowHost?.visible = physical
                    hiddenFullscreen.syncHiddenHoverMonitoring()
                    hiddenFullscreen.hover(true)
                    DispatchQueue.main.advance(0.26)
                    suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty
                                 && hiddenFullscreen.hoverWork == nil && !hiddenFullscreen.peeking
                                 && hiddenFullscreen.openings == 0,
                                 "fullscreen hiding blocks hover unless separately enabled, on every display and opening mode")
                    hiddenFullscreen.hiddenInFullscreen = false
                    hiddenFullscreen.windowHost?.visible = !hides
                    hiddenFullscreen.syncHiddenHoverMonitoring()
                    hiddenFullscreen.hover(true)
                    DispatchQueue.main.advance(0.26)
                    suite.expect(expands ? hiddenFullscreen.openings == 1 : hiddenFullscreen.peeking,
                                 "leaving fullscreen restores the selected hover mode without changing its preferences")
                }
            }
            let cancelledFullscreen = fixture(physical: physical)
            UserDefaults.standard.fullscreenHover = true
            cancelledFullscreen.hiddenInFullscreen = true
            cancelledFullscreen.windowHost?.visible = physical
            cancelledFullscreen.syncHiddenHoverMonitoring()
            cancelledFullscreen.hover(true)
            suite.expect(cancelledFullscreen.hoverWork != nil,
                         "fullscreen hover waits for its configured deadline")
            UserDefaults.standard.fullscreenHover = false
            cancelledFullscreen.syncHiddenHoverMonitoring()
            DispatchQueue.main.advance(0.26)
            suite.expect(cancelledFullscreen.openings == 0 && !cancelledFullscreen.peeking
                         && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "turning off fullscreen hover stops observers and prevents a pending reveal")

            let fullscreenOnly = fixture(physical: physical)
            UserDefaults.standard.enabled = false
            UserDefaults.standard.fullscreenHover = true
            fullscreenOnly.hiddenInFullscreen = true
            fullscreenOnly.windowHost?.visible = physical
            fullscreenOnly.syncHiddenHoverMonitoring()
            fullscreenOnly.hover(true)
            DispatchQueue.main.advance(0.26)
            suite.expect(fullscreenOnly.openings == 1 && fullscreenOnly.openedByHover,
                         "fullscreen-only hover opens independently of click-to-open outside fullscreen")
            leave(fullscreenOnly)
            DispatchQueue.main.advance(UserDefaults.standard.closeDelay + 0.01)
            suite.expect(!fullscreenOnly.expanded,
                         "a fullscreen-only hover opening closes when the pointer leaves")
            fullscreenOnly.hiddenInFullscreen = false
            fullscreenOnly.windowHost?.visible = true
            fullscreenOnly.syncHiddenHoverMonitoring()
            NSEvent.mouseLocation = CGPoint(x: fullscreenOnly.geometry.screen.midX, y: fullscreenOnly.geometry.screen.maxY)
            fullscreenOnly.hover(true)
            DispatchQueue.main.advance(0.26)
            suite.expect(fullscreenOnly.openings == 1 && !fullscreenOnly.peeking
                         && !UserDefaults.standard.enabled && !UserDefaults.standard.hides,
                         "fullscreen-only hover leaves click-to-open and visibility unchanged on the desktop")
        }
        let fullscreen = fixture(physical: true)
        UserDefaults.standard.fullscreenHover = true
        fullscreen.hiddenInFullscreen = true
        fullscreen.compactActivity = .keepAwake
        UserDefaults.standard.hides = true
        UserDefaults.standard.expands = false
        fullscreen.updateBounds()
        let blackSize = fullscreen.surfaceSize
        fullscreen.hover(true)
        suite.expect(blackSize == fullscreen.geometry.restingSize(showsContent: false)
                     && !fullscreen.hoverEmphasized && fullscreen.hoverWork != nil,
                     "fullscreen keeps the cutout black but schedules configured hover access even with an activity running")
        DispatchQueue.main.advance(0.26)
        suite.expect(fullscreen.peeking && fullscreen.openings == 0,
                     "hover preview remains available from the black fullscreen cutout")
        // A simulated cutout kept out of full screen has no window to enter, so
        // the hover set to open it follows the pointer over its place instead.
        for expands in [true, false] {
            let simulatedFullscreen = fixture()
            UserDefaults.standard.fullscreenHover = true
            UserDefaults.standard.expands = expands
            simulatedFullscreen.hiddenInFullscreen = true
            simulatedFullscreen.windowHost?.visible = false
            simulatedFullscreen.syncHiddenHoverMonitoring()
            simulatedFullscreen.syncHiddenHoverMonitoring()
            suite.expect(NSEvent.global.count == 1 && NSEvent.local.count == 1,
                         "a simulated cutout hidden in full screen keeps one pair of movement observers")
            // The strip's far end, beyond the bare cutout full screen keeps.
            let strip = simulatedFullscreen.geometry.collapsed
            NSEvent.mouseLocation = CGPoint(x: simulatedFullscreen.geometry.screen.midX + strip.width / 2 - 2,
                                            y: simulatedFullscreen.geometry.screen.maxY)
            for handler in Array(NSEvent.global.values) { handler(NSEvent()) }
            DispatchQueue.main.advance(0.20)
            suite.expect(simulatedFullscreen.openings == 0 && !simulatedFullscreen.peeking,
                         "a simulated cutout hidden in full screen honors the hover delay")
            DispatchQueue.main.advance(0.06)
            suite.expect(expands ? simulatedFullscreen.openings == 1 && simulatedFullscreen.openedByHover
                                 : simulatedFullscreen.peeking && simulatedFullscreen.openings == 0,
                         "hovering a simulated cutout hidden in full screen opens it as hover is set to")
        }
        let clickFullscreen = fixture()
        UserDefaults.standard.enabled = false
        clickFullscreen.hiddenInFullscreen = true
        clickFullscreen.windowHost?.visible = false
        clickFullscreen.syncHiddenHoverMonitoring()
        clickFullscreen.hover(true)
        DispatchQueue.main.advance(0.26)
        suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty && clickFullscreen.hoverWork == nil
                     && !clickFullscreen.peeking && clickFullscreen.openings == 0,
                     "a simulated cutout hidden in full screen waits for a shortcut when it opens on click")
        let leavingFullscreen = fixture()
        UserDefaults.standard.fullscreenHover = true
        leavingFullscreen.hiddenInFullscreen = true
        leavingFullscreen.windowHost?.visible = false
        leavingFullscreen.syncHiddenHoverMonitoring()
        leavingFullscreen.hiddenInFullscreen = false
        leavingFullscreen.windowHost?.visible = true
        leavingFullscreen.syncHiddenHoverMonitoring()
        suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                     "leaving full screen hands hover back to the island's own window")
        for physical in [false, true] {
            let service = fixture(physical: physical)
            let resting = service.surfaceSize
            service.hover(true)
            let initial = service.hoverWork
            suite.expect(!service.hoverEmphasized && service.surfaceSize == resting && initial != nil,
                         "hover opening keeps either display's island at rest instead of previewing before expansion")
            DispatchQueue.main.advance(0.20)
            suite.expect(service.openings == 0 && service.surfaceSize == resting,
                         "the island stays at rest throughout the configured hover opening delay")
            service.hover(false) // A tracking exit while the pointer is still inside.
            suite.expect(service.hoverWork === initial, "duplicate tracking events preserve the original opening deadline")
            DispatchQueue.main.advance(0.06)
            suite.expect(service.openings == 1 && service.openedByHover && service.hoverWork == nil,
                   "a deliberate hover opens after the default 250 ms on both physical and simulated cutouts")
            leave(service)
            let closing = service.hoverWork
            DispatchQueue.main.advance(0.10)
            service.hover(false)
            suite.expect(service.hoverWork === closing, "overlapping exit events do not postpone closing")
            DispatchQueue.main.advance(0.09)
            suite.expect(service.closures == 1 && service.hoverWork == nil,
                   "leaving either display's expanded island closes it within 190 ms")
            // The exit reported inside started following the pointer; the next
            // move after the island closed hands hover back to window tracking.
            for handler in Array(NSEvent.global.values) { handler(NSEvent()) }
            suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                   "the first move after the hover-opened island closed releases the pointer observers")
        }
        for physical in [false, true] {
            for local in [false, true] {
                let hidden = fixture(physical: physical)
                UserDefaults.standard.hides = true
                hidden.windowHost?.visible = false
                hidden.notice = layout // A notice already present when the preference changes.
                hidden.syncHiddenHoverMonitoring()
                for _ in 0..<100 { hidden.syncHiddenHoverMonitoring() }
                suite.expect(NSEvent.global.count == 1 && NSEvent.local.count == 1,
                       "hidden mode keeps one pair of native movement observers")
                func move(to point: CGPoint) {
                    NSEvent.mouseLocation = point
                    let event = NSEvent()
                    if local {
                        for handler in Array(NSEvent.local.values) {
                            suite.expect(handler(event) === event, "hidden hover never consumes the original local event")
                        }
                    } else { for handler in Array(NSEvent.global.values) { handler(event) } }
                }
                let top = CGPoint(x: hidden.geometry.screen.midX, y: hidden.geometry.screen.maxY)
                move(to: top)
                DispatchQueue.main.advance(0.20)
                suite.expect(hidden.openings == 0, "a hidden island honors the saved activation delay")
                move(to: CGPoint(x: hidden.geometry.screen.minX, y: hidden.geometry.screen.minY))
                DispatchQueue.main.advance(0.20)
                suite.expect(hidden.openings == 0, "leaving the invisible region cancels pending activation")
                move(to: top)
                DispatchQueue.main.advance(0.26)
                suite.expect(hidden.openings == 1 && hidden.openedByHover,
                       "local and global movement reveal either display without a visible window or menu measurement")
                hidden.windowHost?.visible = true
                hidden.syncHiddenHoverMonitoring()
                suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                       "revealing hands hover back to native window tracking")
                leave(hidden)
                DispatchQueue.main.advance(0.20)
                suite.expect(hidden.closures == 1 && hidden.hiddenUntilHover,
                       "leaving returns the revealed island to its hidden state")
                hidden.syncHiddenHoverMonitoring()
                hidden.running = false
                hidden.syncHiddenHoverMonitoring()
                suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                       "stopping releases both hidden hover observers")
            }
        }
        for expands in [false, true] {
            let hidden = fixture()
            UserDefaults.standard.hides = true
            UserDefaults.standard.expands = expands
            hidden.windowHost?.visible = false
            hidden.windowHost?.isConcealedForMissionControl = true
            hidden.hover(true)
            suite.expect(!hidden.inside && hidden.hoverWork == nil,
                         "Mission Control cannot start a hidden island's hover deadline")
            hidden.windowHost?.isConcealedForMissionControl = false
            hidden.hover(true)
            suite.expect(hidden.inside && hidden.hoverWork != nil,
                         "leaving Mission Control allows a fresh hidden hover deadline")
            hidden.windowHost?.isConcealedForMissionControl = true
            DispatchQueue.main.advance(0.26)
            suite.expect(hidden.openings == 0 && !hidden.peeking && hidden.windowHost?.revealChecks == 1,
                         "Mission Control starting during the hover delay blocks expansion and preview")

            let visible = fixture()
            UserDefaults.standard.expands = expands
            visible.hover(true)
            suite.expect(visible.inside && visible.hoverWork != nil,
                         "a visible island has a pending hover deadline before Mission Control")
            visible.windowHost?.isConcealedForMissionControl = true
            DispatchQueue.main.advance(0.26)
            suite.expect(visible.openings == 0 && !visible.peeking && visible.windowHost?.revealChecks == 1,
                         "Mission Control blocks a pending visible hover without a mouse-exit event")
            visible.windowHost?.isConcealedForMissionControl = false
            visible.missionControlDidRestore()
            suite.expect(visible.hoverWork != nil,
                         "restoring Mission Control restarts a hover deadline when the pointer stayed over the island")
            DispatchQueue.main.advance(0.26)
            suite.expect(expands ? visible.openings == 1 : visible.peeking,
                         "the restored hover opens the island after its normal delay")
        }
        let departed = fixture()
        departed.hover(true)
        DispatchQueue.main.advance(0.26)
        suite.expect(departed.expanded && departed.openedByHover,
                     "the island is open from hover before Mission Control")
        departed.windowHost?.isConcealedForMissionControl = true
        NSEvent.mouseLocation = CGPoint(x: departed.geometry.screen.minX, y: departed.geometry.screen.minY)
        departed.windowHost?.isConcealedForMissionControl = false
        departed.missionControlDidRestore()
        suite.expect(!departed.inside && departed.hoverWork != nil,
                     "restoration notices that the pointer left while Mission Control owned input")
        DispatchQueue.main.advance(0.19)
        suite.expect(departed.closures == 1,
                     "the hover-open island closes after its normal pointer exit delay")

        // AppKit's last exit can come while the pointer is still in the margin
        // around the floating controls. Leaving from there over transparent
        // pixels or out of the window reports nothing more to the island.
        func openWithPointerInMargin() -> Service {
            let service = fixture()
            service.hover(true)
            DispatchQueue.main.advance(0.26)
            let island = service.windowHost!.rect
            service.windowHost?.controls = [CGRect(x: island.midX - 38, y: island.minY - 72, width: 76, height: 88)]
            NSEvent.mouseLocation = CGPoint(x: island.midX, y: island.minY - 60)
            service.hover(false)
            return service
        }
        func follow(to point: CGPoint, local: Bool = false) {
            NSEvent.mouseLocation = point
            let event = NSEvent()
            if local {
                for handler in Array(NSEvent.local.values) {
                    suite.expect(handler(event) === event, "following the pointer never consumes its local event")
                }
            } else { for handler in Array(NSEvent.global.values) { handler(event) } }
        }
        let margin = openWithPointerInMargin()
        let island = margin.windowHost!.rect
        suite.expect(margin.expanded && margin.inside && margin.hoverWork == nil
                     && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                     "an exit reported in the controls' margin keeps the island open and follows the pointer")
        follow(to: CGPoint(x: island.midX + 20, y: island.minY - 30), local: true)
        DispatchQueue.main.advance(0.5)
        suite.expect(margin.expanded && margin.closures == 0, "slow travel through the margin keeps the island open")
        follow(to: CGPoint(x: island.midX, y: island.minY - 400))
        DispatchQueue.main.advance(0.10)
        follow(to: CGPoint(x: island.midX - 20, y: island.minY - 50))
        DispatchQueue.main.advance(0.20)
        suite.expect(margin.expanded && margin.closures == 0,
                     "slipping back into the margin unreported cancels the pending close")
        follow(to: CGPoint(x: island.midX, y: island.minY - 400))
        DispatchQueue.main.advance(0.19)
        suite.expect(margin.closures == 1, "leaving from the margin with no further report still closes the island")
        follow(to: CGPoint(x: island.midX, y: island.minY - 420))
        suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty, "the closed island stops following the pointer")

        let reported = openWithPointerInMargin()
        reported.hover(true)
        suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty && reported.expanded,
                     "an entry AppKit reports hands hover back to its tracking")
        let stopped = openWithPointerInMargin()
        stopped.running = false
        follow(to: CGPoint(x: island.midX, y: island.minY - 400))
        suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty && stopped.closures == 0,
                     "stopping the island releases the pointer observers")
        // Pinning, or a menu or dialog, keeps the island and ends the watch. A
        // menu that closes with the pointer still in the margin starts it again.
        for protect: (Service) -> Void in [{ $0.pinned = true }, { $0.keepsWorkingSurface = true }] {
            let held = openWithPointerInMargin()
            protect(held)
            follow(to: CGPoint(x: island.midX, y: island.minY - 400))
            DispatchQueue.main.advance(1)
            suite.expect(held.expanded && held.closures == 0 && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "pinning, a menu or a dialog keeps the island and stops following the pointer")
        }
        let menu = openWithPointerInMargin()
        menu.keepsWorkingSurface = true
        follow(to: CGPoint(x: island.midX + 20, y: island.minY - 30))
        menu.keepsWorkingSurface = false
        menu.hover(false)
        suite.expect(NSEvent.global.count == 1 && NSEvent.local.count == 1,
                     "a menu that closes with the pointer in the margin follows the pointer again")
        follow(to: CGPoint(x: island.midX, y: island.minY - 400))
        DispatchQueue.main.advance(0.19)
        follow(to: CGPoint(x: island.midX, y: island.minY - 420))
        suite.expect(menu.closures == 1 && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                     "leaving after the menu closes the island and releases the pointer observers")
        let clickOpened = fixture()
        clickOpened.open(takeFocus: true)
        clickOpened.windowHost?.controls = [CGRect(x: island.midX - 38, y: island.minY - 72, width: 76, height: 88)]
        NSEvent.mouseLocation = CGPoint(x: island.midX, y: island.minY - 60)
        clickOpened.hover(false)
        suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                     "an island opened by a click, which leaving does not close, never follows the pointer")
        // Passing quickly over the closed island to a display above: the last
        // exit arrives while the pointer still touches the island's top edge.
        do {
            let passed = fixture()
            UserDefaults.standard.enabled = false
            let top = passed.windowHost!.rect
            NSEvent.mouseLocation = CGPoint(x: top.midX, y: top.maxY - 1)
            passed.hover(true)
            passed.hover(false)
            suite.expect(passed.hoverEmphasized && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                         "an exit reported at the top edge keeps the emphasis and follows the pointer")
            follow(to: CGPoint(x: top.midX, y: top.maxY + 300))
            suite.expect(!passed.hoverEmphasized && !passed.inside,
                         "the first move on the display above clears the closed island's hover emphasis")
            suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "the closed island stops following the pointer once the emphasis is gone")
            // Fast enough, AppKit reports no exit at all after the entry.
            let silent = fixture()
            UserDefaults.standard.enabled = false
            NSEvent.mouseLocation = CGPoint(x: top.midX, y: top.maxY - 1)
            silent.hover(true)
            suite.expect(silent.hoverEmphasized && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                         "the closed island follows the pointer while its hover emphasis shows")
            follow(to: CGPoint(x: top.midX + 10, y: top.maxY - 2))
            suite.expect(silent.hoverEmphasized, "moving over the island keeps its hover emphasis")
            follow(to: CGPoint(x: top.midX, y: top.maxY + 300))
            suite.expect(!silent.hoverEmphasized && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "an unreported exit to the display above still clears the emphasis and its observers")
            // A notice that holds back a preview leaves the island emphasized
            // under a resting pointer, so following goes on past the deadline.
            let interrupted = fixture()
            UserDefaults.standard.expands = false
            NSEvent.mouseLocation = CGPoint(x: top.midX, y: top.maxY - 1)
            interrupted.hover(true)
            interrupted.notice = layout
            DispatchQueue.main.advance(1)
            interrupted.notice = nil
            suite.expect(!interrupted.peeking && interrupted.hoverWork == nil && interrupted.hoverEmphasized
                         && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                         "a preview a notice held back keeps following the emphasized island")
            follow(to: CGPoint(x: top.midX, y: top.maxY + 300))
            suite.expect(!interrupted.hoverEmphasized && !interrupted.inside
                         && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "an unreported exit after the notice still clears the emphasis and its observers")
            // A second activity that starts during a hover opening shows the
            // picker instead, which still needs the pointer followed out.
            let joined = fixture()
            joined.compactActivity = .agents
            joined.compactActivities = [.agents]
            NSEvent.mouseLocation = CGPoint(x: top.midX, y: top.maxY - 1)
            joined.hover(true)
            joined.compactActivities = [.agents, .keepAwake]
            DispatchQueue.main.advance(1)
            suite.expect(joined.openings == 0 && joined.showsCompactActivityPicker
                         && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                         "a picker that appears during a hover opening keeps following the pointer")
            follow(to: CGPoint(x: top.midX, y: top.maxY + 300))
            suite.expect(!joined.showsCompactActivityPicker && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "an unreported exit to the display above still hides that picker and releases its observers")
        }
        // A full opening has no hover emphasis, but still needs an uninterrupted
        // stay. Leaving without a tracking exit must discard the old deadline.
        for physical in [false, true] {
            for reduced in [false, true] {
                for local in [false, true] {
                    let returning = fixture(physical: physical)
                    UserDefaults.standard.delay = 0.6
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = reduced
                    let top = returning.windowHost!.rect
                    let entry = CGPoint(x: top.midX, y: top.maxY - 1)
                    let resting = returning.surfaceSize
                    NSEvent.mouseLocation = entry
                    returning.hover(true)
                    let first = returning.hoverWork
                    suite.expect(!returning.hoverEmphasized && returning.surfaceSize == resting
                                 && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                                 "hover opening follows the pointer without emphasizing the island, including Reduce Motion")
                    DispatchQueue.main.advance(0.4)
                    follow(to: CGPoint(x: top.midX, y: top.maxY + 300), local: local)
                    suite.expect(!returning.inside && first?.isCancelled == true && returning.hoverWork == nil,
                                 "a move to the display above cancels the opening even without an AppKit tracking exit")
                    suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                                 "leaving a pending hover opening releases both pointer observers")
                    DispatchQueue.main.advance(0.05)
                    NSEvent.mouseLocation = entry
                    returning.hover(true)
                    suite.expect(returning.hoverWork != nil && returning.hoverWork !== first,
                                 "returning after an unreported exit starts a fresh hover deadline")
                    DispatchQueue.main.advance(0.16)
                    suite.expect(returning.openings == 0 && returning.surfaceSize == resting,
                                 "the original opening deadline cannot open an island the pointer left and reentered")
                    DispatchQueue.main.advance(0.43)
                    suite.expect(returning.openings == 0,
                                 "reentry waits for the full configured delay")
                    DispatchQueue.main.advance(0.02)
                    suite.expect(returning.openings == 1 && returning.openedByHover
                                 && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                                 "the fresh hover opens once and releases the pending opening's pointer observers")
                    returning.collapse()
                    returning.hover(true)
                    suite.expect(returning.hoverState.suppressed && returning.hoverWork == nil
                                 && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                                 "an explicit close under the pointer follows its departure without reopening")
                    follow(to: CGPoint(x: top.midX, y: top.maxY + 300), local: local)
                    suite.expect(!returning.hoverState.suppressed && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                                 "an unreported departure rearms hover after an explicit close and releases its observers")
                    NSEvent.mouseLocation = entry
                    returning.hover(true)
                    DispatchQueue.main.advance(0.59)
                    suite.expect(returning.openings == 1, "reopening after an explicit close waits for the full hover delay")
                    DispatchQueue.main.advance(0.02)
                    suite.expect(returning.openings == 2 && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                                 "the first return after an explicit close opens normally even without a tracking exit")
                }
            }
        }
        // Set to show activity, a hidden island beside a simulated cutout
        // draws one only with room from the menus. With none it stays out of
        // sight, so it keeps following the pointer to open where it waits.
        for silhouette in [NotchSilhouette.notch, .capsule] {
            for room in [64, nil] as [CGFloat?] {
                let waiting = fixture()
                UserDefaults.standard.hides = true
                waiting.hiddenShowsActivity = true
                waiting.geometry = NotchGeometry(screen: waiting.geometry.screen, safeAreaTop: 0, cameraWidth: 0,
                                                 menuBarHeight: 22, compactSideRoom: room, silhouette: silhouette)
                waiting.compactActivity = .keepAwake
                waiting.compactActivities = [.keepAwake]
                waiting.windowHost?.visible = room != nil
                waiting.updateBounds()
                waiting.syncHiddenHoverMonitoring()
                guard room == nil else {
                    suite.expect(!waiting.hiddenUntilHover && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                                 "with room beside a simulated cutout, a hidden island set to show activity shows it")
                    continue
                }
                suite.expect(waiting.hiddenUntilHover && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                             "with no room beside a simulated cutout, a hidden island set to show activity waits out of sight")
                let place = waiting.geometry.frame(for: waiting.geometry.collapsed)
                follow(to: CGPoint(x: place.midX, y: place.minY - 200))
                follow(to: CGPoint(x: place.midX, y: place.maxY - 1))
                DispatchQueue.main.advance(0.26)
                suite.expect(waiting.openings == 1 && waiting.openedByHover,
                             "with no room beside a simulated cutout, a hidden island set to show activity still opens under the pointer")
            }
        }
        // Opening or peeking on hover ends the closed island's follow at once,
        // so the next move cannot tell a page or preview the pointer left.
        for expands in [true, false] {
            let opening = fixture()
            UserDefaults.standard.expands = expands
            let top = opening.windowHost!.rect
            NSEvent.mouseLocation = CGPoint(x: top.midX, y: top.maxY - 1)
            opening.hover(true)
            suite.expect(opening.hoverEmphasized == !expands && NSEvent.global.count == 1 && NSEvent.local.count == 1,
                         "both hover modes follow the pointer before revealing content, while only the preview emphasizes it")
            DispatchQueue.main.advance(0.26)
            suite.expect((expands ? opening.openings == 1 : opening.peeking)
                            && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "opening or peeking on hover drops the closed island's pointer observers")
        }
        for disable: (Service) -> Void in [
            { $0.suspended = true }, { $0.windowHost = nil },
            { _ in UserDefaults.standard.hides = false }, { _ in UserDefaults.standard.enabled = false }
        ] {
            let hidden = fixture()
            UserDefaults.standard.hides = true
            hidden.syncHiddenHoverMonitoring()
            disable(hidden)
            hidden.syncHiddenHoverMonitoring()
            suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                   "suspension, missing display and preference changes release hidden hover observers")
        }
        let passing = fixture()
        passing.hover(true)
        DispatchQueue.main.advance(0.20)
        leave(passing)
        DispatchQueue.main.advance(1)
        suite.expect(passing.openings == 0, "leaving before the opening deadline cancels expansion")

        let reentering = fixture()
        reentering.hover(true)
        DispatchQueue.main.advance(0.20)
        leave(reentering)
        DispatchQueue.main.advance(0.02)
        NSEvent.mouseLocation = CGPoint(x: reentering.geometry.screen.midX, y: reentering.geometry.screen.maxY)
        reentering.hover(true)
        DispatchQueue.main.advance(0.20)
        suite.expect(reentering.openings == 0, "separate short passes cannot accumulate time toward opening")
        DispatchQueue.main.advance(0.06)
        suite.expect(reentering.openings == 1, "reentering requires a fresh uninterrupted activation delay")

        for delay in [0.10, 0.25, 0.65, 1.0] {
            for expands in [false, true] {
                let custom = fixture()
                UserDefaults.standard.delay = delay
                UserDefaults.standard.expands = expands
                custom.hover(true)
                DispatchQueue.main.advance(delay - 0.01)
                suite.expect(custom.openings == 0 && !custom.peeking, "hover waits for the full configured delay in both opening modes")
                DispatchQueue.main.advance(0.02)
                suite.expect(expands ? custom.openings == 1 : custom.peeking,
                       "both expansion and preview honor the selected activation time")
            }
        }

        let adjusted = fixture()
        adjusted.hover(true)
        leave(adjusted)
        UserDefaults.standard.delay = 0.65
        NSEvent.mouseLocation = CGPoint(x: adjusted.geometry.screen.midX, y: adjusted.geometry.screen.maxY)
        adjusted.hover(true)
        DispatchQueue.main.advance(0.30)
        suite.expect(adjusted.openings == 0, "a changed activation time applies on the next entry without restarting")
        DispatchQueue.main.advance(0.36)
        suite.expect(adjusted.openings == 1, "the updated activation time completes normally")

        for physical in [false, true] {
            for hides in [false, true] {
                for delay in [0.10, 0.18, 0.65, 1.5, 2.0] {
                    let custom = fixture(physical: physical)
                    UserDefaults.standard.hides = hides
                    UserDefaults.standard.closeDelay = delay
                    custom.hover(true)
                    DispatchQueue.main.advance(0.26)
                    leave(custom)
                    let closing = custom.hoverWork
                    DispatchQueue.main.advance(delay - 0.01)
                    suite.expect(custom.closures == 0, "a hover-opened island waits for the selected closing time")
                    custom.hover(false)
                    suite.expect(custom.hoverWork === closing, "duplicate exits preserve a custom closing deadline")
                    DispatchQueue.main.advance(0.02)
                    suite.expect(custom.closures == 1 && custom.hoverWork == nil,
                                 "the selected closing time applies to visible and hidden islands on either display")
                }
            }
        }

        let changedClosing = fixture()
        changedClosing.hover(true)
        DispatchQueue.main.advance(0.26)
        UserDefaults.standard.closeDelay = 1.5
        leave(changedClosing)
        DispatchQueue.main.advance(1.0)
        suite.expect(changedClosing.closures == 0, "a changed closing time applies on the next exit without restarting")
        NSEvent.mouseLocation = CGPoint(x: changedClosing.geometry.screen.midX, y: changedClosing.geometry.screen.maxY)
        changedClosing.hover(true)
        DispatchQueue.main.advance(1.0)
        suite.expect(changedClosing.closures == 0 && changedClosing.openings == 1,
                     "returning during a custom closing delay cancels the close without reopening")

        for protect: (Service) -> Void in [
            { $0.running = false }, { $0.pinned = true }, { $0.keepsWorkingSurface = true }
        ] {
            let protected = fixture()
            UserDefaults.standard.closeDelay = 1.5
            protected.hover(true)
            DispatchQueue.main.advance(0.26)
            leave(protected)
            protect(protected)
            DispatchQueue.main.advance(1.51)
            suite.expect(protected.closures == 0 && protected.hoverWork == nil,
                         "a custom closing deadline rechecks whether the island may collapse")
        }

        let active = fixture()
        active.compactActivity = .keepAwake
        active.hover(true)
        DispatchQueue.main.advance(0.26)
        expect(active.openings == 1 && active.requestedModule == nil,
               "hover opens without naming a page, so the island's own reopening rule decides")

        let returning = fixture()
        returning.hover(true)
        DispatchQueue.main.advance(0.26)
        leave(returning)
        DispatchQueue.main.advance(0.10)
        NSEvent.mouseLocation = CGPoint(x: returning.geometry.screen.midX, y: returning.geometry.screen.maxY)
        returning.hover(true)
        DispatchQueue.main.advance(1)
        suite.expect(returning.openings == 1 && returning.closures == 0,
               "returning before the closing deadline cancels closing without reopening")

        let preview = fixture()
        UserDefaults.standard.expands = false
        UserDefaults.standard.closeDelay = 2.0
        preview.hover(true)
        DispatchQueue.main.advance(0.26)
        suite.expect(preview.peeking && preview.openings == 0 && preview.feedbacks == 1 && preview.hoverWork == nil,
               "preview-only mode responds promptly without expanding the panel")
        leave(preview)
        DispatchQueue.main.advance(0.13)
        suite.expect(preview.closures == 1, "a preview keeps its own closing delay when an expansion delay was saved")

        for protect: (Service) -> Void in [
            { $0.pinned = true }, { $0.keepsWorkingSurface = true }, { $0.hoverState.close(pointerInside: true) },
            { $0.notice = layout }, { $0.suspended = true }, { $0.running = false },
            { _ in UserDefaults.standard.enabled = false }
        ] {
            let protected = fixture()
            protected.hover(true)
            protect(protected)
            DispatchQueue.main.advance(1)
            suite.expect(protected.openings == 0 && protected.hoverWork == nil,
                   "a pending hover rechecks eligibility before opening")
            follow(to: CGPoint(x: protected.geometry.screen.minX, y: protected.geometry.screen.minY))
            suite.expect(NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                         "an aborted hover opening releases its pointer observers once the pointer moves away")
        }
        for protect: (Service) -> Void in [
            { $0.pinned = true }, { $0.keepsWorkingSurface = true }, { $0.suspended = true }, { $0.running = false }
        ] {
            let protected = fixture()
            protected.open(nil, takeFocus: false)
            leave(protected)
            protect(protected)
            DispatchQueue.main.advance(1)
            suite.expect(protected.closures == 0 && protected.hoverWork == nil,
                   "a pending departure cannot interrupt pinning, a menu or suspension")
        }
        let clicked = fixture()
        clicked.open(nil, takeFocus: true)
        leave(clicked)
        DispatchQueue.main.advance(1)
        suite.expect(clicked.closures == 0, "a panel opened by click stays open when the pointer leaves")

        let keyboard = fixture()
        keyboard.open(nil, takeFocus: false)
        leave(keyboard)
        AssistiveKeyboard.active = true
        DispatchQueue.main.advance(1)
        expect(keyboard.closures == 0, "moving to the Accessibility Keyboard preserves the working panel")

        let popover = fixture()
        popover.open(nil, takeFocus: false)
        popover.childWindowFrames = [CGRect(x: popover.geometry.screen.minX, y: popover.geometry.screen.minY,
                                            width: 240, height: 200)]
        leave(popover)
        DispatchQueue.main.advance(1)
        expect(popover.closures == 0 && popover.inside,
               "moving into a popover hanging from the island keeps a hover-opened panel")
    }
}
