// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Production routing and lifecycle with controlled event delivery, never posted input.
enum NotchScreenEdgeClickTests {
    final class Panel { var isVisible = true; var ignoresMouseEvents = false }
    final class Host {
        var acceptsPoint = true, isConcealedForMissionControl = false
        func containsDestination(_ point: CGPoint) -> Bool { acceptsPoint }
    }
    enum NSScreen {
        static var withMenuBar: Screen? = Screen()
        struct Screen { let frame = CGRect(x: 0, y: 0, width: 1470, height: 956) }
    }
    final class NSEvent {
        typealias EventType = AppKit.NSEvent.EventType
        typealias EventTypeMask = AppKit.NSEvent.EventTypeMask
        struct CGEvent { let location: CGPoint }
        let type: EventType
        let cgEvent: CGEvent?
        let window: Panel?
        init(_ type: EventType, point: CGPoint, window: Panel? = nil) {
            self.type = type
            cgEvent = CGEvent(location: CGPoint(x: point.x, y: 956 - point.y))
            self.window = window
        }
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
    class State {
        var running = true, suspended = false, expanded = false, peeking = false
        var notice: NotchNotice?, departingNotice: NotchNotice?
        var hiddenInFullscreen = false, routesNotices = true
        var compactActivityIsVisible = false, keepsWorkingSurface = false
        var panel: Panel? = Panel()
        var windowHost: Host? = Host()
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                     safeAreaTop: 32, cameraWidth: 180)
        var compactActivityGeometry: NotchGeometry { geometry }
        var hoverEmphasized = false
        var surfaceSize: CGSize {
            if let notice {
                return geometry.floats ? capsuleNoticeSurface(notice) : geometry.noticeSize(wings: notice.wings(in: geometry))
            }
            let size = peeking ? geometry.expanded : compactActivityIsVisible ? geometry.compactActivitySize : geometry.collapsed
            return hoverEmphasized ? NotchHoverEmphasis.size(from: size, geometry: geometry) : size
        }
        var screenEdgeClickMonitors: [Any] = []
        var screenEdgePress: (area: CGRect, point: CGPoint, notice: NotchNotice?)?
        var hoverWork: DispatchWorkItem?
        var hoverState = NotchHoverState()
        var compactActivity: NotchCompactActivity?
        var openings = 0
        var opened: NotchModule?
        func dismissNotice() { notice = nil; departingNotice = nil }
    }

    private static let copied = NotchNotice(event: .clipboard, title: "Copied", detail: "Text", symbol: "doc.on.clipboard")
    private static let layout = NotchNotice(event: .inputSource, title: "ABC", detail: "ABC", symbol: "keyboard")

    static func run(_ suite: TestSuite) {
        for screen in [CGRect(x: 0, y: 0, width: 1470, height: 956),
                       CGRect(x: -1920, y: 956, width: 1920, height: 1080)] {
            for localDelivery in [false, true] {
                let service = Service()
                service.geometry = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 180)
                service.syncScreenEdgeClicks()
                for _ in 0..<100 { service.syncScreenEdgeClicks() }
                suite.expect(NSEvent.global.count == 1 && NSEvent.local.count == 1, "refreshes keep exactly one pair of edge-click monitors")
                let top = CGPoint(x: screen.midX, y: screen.maxY)
                func send(_ type: NSEvent.EventType, _ point: CGPoint, window: Panel? = nil) {
                    let event = NSEvent(type, point: point, window: window)
                    if localDelivery {
                        for handler in Array(NSEvent.local.values) {
                            suite.expect(handler(event) === event, "local observation preserves normal event delivery")
                        }
                    } else { for handler in Array(NSEvent.global.values) { handler(event) } }
                }
                send(.leftMouseUp, top)
                send(.leftMouseDown, CGPoint(x: screen.minX, y: screen.maxY)); send(.leftMouseUp, top)
                send(.leftMouseDown, CGPoint(x: top.x, y: top.y - 2)); send(.leftMouseUp, top)
                send(.leftMouseDown, CGPoint(x: top.x, y: top.y + 0.5)); send(.leftMouseUp, top)
                send(.leftMouseDown, top, window: service.panel); send(.leftMouseUp, top)
                suite.expect(service.openings == 0, "release-only, nearby menus, lower clicks and native notch clicks never cause duplicate opening")
                send(.leftMouseDown, top); send(.leftMouseDragged, CGPoint(x: screen.minX, y: screen.maxY)); send(.leftMouseUp, top)
                send(.leftMouseDown, top); send(.leftMouseUp, CGPoint(x: screen.minX, y: screen.maxY))
                suite.expect(service.openings == 0, "dragging off the island or releasing outside cancels an edge click")
                service.windowHost?.acceptsPoint = false
                send(.leftMouseDown, top); send(.leftMouseUp, top)
                service.windowHost?.acceptsPoint = true
                service.keepsWorkingSurface = true
                send(.leftMouseDown, top); send(.leftMouseUp, top)
                service.keepsWorkingSurface = false
                suite.expect(service.openings == 0, "transparent corners and an active menu or modal preserve their own interactions")
                let pendingHover = DispatchWorkItem {}
                service.hoverWork = pendingHover
                send(.leftMouseDown, top)
                suite.expect(service.openings == 0 && pendingHover.isCancelled && service.hoverState.suppressed,
                       "pressing the edge cancels hover and waits for release")
                send(.leftMouseUp, CGPoint(x: top.x, y: top.y - 0.5))
                suite.expect(service.openings == 1 && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                       "a menu-bar click opens exactly once on either display, then removes both monitors")
                service.removeScreenEdgeClickMonitors()
            }
        }
        for disable in [
            { (s: Service) in s.running = false }, { $0.suspended = true }, { $0.expanded = true },
            { $0.panel?.isVisible = false }, { $0.panel?.ignoresMouseEvents = true }
        ] {
            let service = Service()
            service.syncScreenEdgeClicks()
            let point = CGPoint(x: service.geometry.screen.midX, y: service.geometry.screen.maxY)
            service.handleScreenEdgeClick(.leftMouseDown, at: point, isNotchWindow: false)
            disable(service)
            service.syncScreenEdgeClicks()
            service.handleScreenEdgeClick(.leftMouseUp, at: point, isNotchWindow: false)
            suite.expect(service.openings == 0 && service.screenEdgePress == nil
                   && NSEvent.global.isEmpty && NSEvent.local.isEmpty,
                   "leaving an eligible presentation cancels the press and removes every monitor")
        }
        let steady = Service()
        steady.syncScreenEdgeClicks()
        let edge = CGPoint(x: steady.geometry.screen.midX, y: steady.geometry.screen.maxY)
        steady.handleScreenEdgeClick(.leftMouseDown, at: edge, isNotchWindow: false)
        steady.handleScreenEdgeClick(.leftMouseDragged, at: edge, isNotchWindow: false)
        steady.handleScreenEdgeClick(.leftMouseDragged, at: CGPoint(x: edge.x + 3, y: edge.y - 2), isNotchWindow: false)
        steady.handleScreenEdgeClick(.leftMouseUp, at: edge, isNotchWindow: false)
        suite.expect(steady.openings == 1,
               "the drag a press at the screen's edge reports, within the island, keeps the click")
        steady.removeScreenEdgeClickMonitors()
        let late = Service()
        late.geometry = NotchGeometry(screen: late.geometry.screen, safeAreaTop: 32, cameraWidth: 180, compactSideRoom: 64)
        late.syncScreenEdgeClicks()
        guard let resting = late.screenEdgeClickArea else { suite.expect(false, "a resting island takes edge clicks"); return }
        let centre = CGPoint(x: resting.midX, y: resting.maxY)
        late.handleScreenEdgeClick(.leftMouseDown, at: centre, isNotchWindow: false)
        // The entry is reported after the press, so the pulse lands before the release.
        late.hoverEmphasized = true
        guard let pulsed = late.screenEdgeClickArea else { suite.expect(false, "a pulsing island takes edge clicks"); return }
        // Released where only the grown island reaches.
        late.handleScreenEdgeClick(.leftMouseUp, at: CGPoint(x: pulsed.maxX - 4, y: pulsed.maxY), isNotchWindow: false)
        suite.expect(pulsed.maxX - 4 > resting.maxX && late.openings == 1,
                     "a click the hover pulse grows under still opens the island")
        late.removeScreenEdgeClickMonitors()
        let service = Service()
        service.geometry = NotchGeometry(screen: service.geometry.screen, safeAreaTop: 0, cameraWidth: 0, compactSideRoom: 0)
        service.compactActivityIsVisible = true
        service.syncScreenEdgeClicks()
        suite.expect(service.screenEdgeClickArea?.width == service.geometry.cameraWidth
               && service.screenEdgeClickArea?.maxY == service.geometry.screen.maxY,
               "the simulated camera retains the same screen-edge activation area as a physical cutout")
        let point = CGPoint(x: service.geometry.screen.midX, y: service.geometry.screen.maxY)
        service.handleScreenEdgeClick(.leftMouseDown, at: point, isNotchWindow: false)
        service.handleScreenEdgeClick(.leftMouseUp, at: point, isNotchWindow: false)
        suite.expect(service.openings == 1 && service.screenEdgeClickMonitors.isEmpty,
               "clicking the top edge opens a simulated notch exactly once and stops its closed-state monitors")
        // A capsule floats below the top edge; the menu bar above it still
        // opens it, and the capsule itself takes its own clicks.
        for (depth, opens) in [(CGFloat(0), true), (1.5, true), (2.5, true), (3.5, false)] {
            let capsule = Service()
            capsule.geometry = NotchGeometry(screen: capsule.geometry.screen, safeAreaTop: 0, cameraWidth: 0,
                                             compactSideRoom: 64, silhouette: .capsule)
            capsule.syncScreenEdgeClicks()
            let point = CGPoint(x: capsule.geometry.screen.midX, y: capsule.geometry.screen.maxY - depth)
            capsule.handleScreenEdgeClick(.leftMouseDown, at: point, isNotchWindow: false)
            capsule.handleScreenEdgeClick(.leftMouseUp, at: point, isNotchWindow: false)
            suite.expect(capsule.openings == (opens ? 1 : 0),
                         "a click \(depth) points below the top edge \(opens ? "opens" : "leaves") a floating capsule")
            capsule.removeScreenEdgeClickMonitors()
        }
        runNotices(suite)
        runReplacedNotices(suite)
        runMenuClearance(suite)
        runChangingNotices(suite)
    }

    private static func runNotices(_ suite: TestSuite) {
        // The menu bar owns the top row, so a notice needs these clicks as much
        // as the resting island does, and each one opens where it leads.
        for (shown, module) in [(copied, NotchModule.clipboard), (layout, .controls)] {
            let service = Service()
            service.notice = shown
            service.syncScreenEdgeClicks()
            let top = CGPoint(x: service.geometry.screen.midX, y: service.geometry.screen.maxY)
            service.handleScreenEdgeClick(.leftMouseDown, at: top, isNotchWindow: false)
            service.handleScreenEdgeClick(.leftMouseUp, at: top, isNotchWindow: false)
            suite.expect(service.openings == 1 && service.opened == module && service.expanded,
                         "a top-edge click on a \(shown.event) notice opens its page")
            suite.expect(service.notice == nil, "a \(shown.event) notice that opened its page does not return after closing")
            suite.expect(service.screenEdgeClickMonitors.isEmpty, "opening from a notice removes the edge monitors")
        }
        let native = Service()
        native.notice = copied
        native.syncScreenEdgeClicks()
        let nativeTop = CGPoint(x: native.geometry.screen.midX, y: native.geometry.screen.maxY)
        native.handleScreenEdgeClick(.leftMouseDown, at: nativeTop, isNotchWindow: true)
        native.handleScreenEdgeClick(.leftMouseUp, at: nativeTop, isNotchWindow: true)
        suite.expect(native.openings == 0, "a click the notice's own window receives is not handled twice")
        native.removeScreenEdgeClickMonitors()
        // The notice's button stays on screen while it closes.
        let closing = Service()
        closing.departingNotice = copied
        closing.activateNotice(copied)
        suite.expect(closing.openings == 1 && closing.opened == .clipboard && closing.departingNotice == nil,
                     "a click on a closing notice opens its page")
        let stale = Service()
        stale.notice = layout
        stale.departingNotice = copied
        stale.activateNotice(copied)
        suite.expect(stale.openings == 0 && stale.notice == layout, "a superseded outgoing button leaves the new notice alone")
        // The normal activity is Keep Awake. Releasing this press must still open the clipboard.
        for stillDeparting in [true, false] {
            let expiring = Service()
            expiring.compactActivity = .keepAwake
            expiring.notice = copied
            expiring.syncScreenEdgeClicks()
            let top = CGPoint(x: expiring.geometry.screen.midX, y: expiring.geometry.screen.maxY)
            menuBarEvent(.leftMouseDown, at: top)
            expiring.notice = nil
            expiring.departingNotice = stillDeparting ? copied : nil
            expiring.syncScreenEdgeClicks()
            menuBarEvent(.leftMouseUp, at: top)
            suite.expect(expiring.openings == 1 && expiring.opened == .clipboard,
                         "the press keeps the clipboard through the outgoing animation and after expiry")
        }
        // A press lands on the resting island and a notice arrives before the release.
        let arriving = Service()
        arriving.syncScreenEdgeClicks()
        let arrivingTop = CGPoint(x: arriving.geometry.screen.midX, y: arriving.geometry.screen.maxY)
        arriving.handleScreenEdgeClick(.leftMouseDown, at: arrivingTop, isNotchWindow: false)
        arriving.notice = layout
        arriving.handleScreenEdgeClick(.leftMouseUp, at: arrivingTop, isNotchWindow: false)
        suite.expect(arriving.openings == 1 && arriving.opened == nil,
                     "a press on the resting island keeps its normal opening when a notice arrives")
        // The menu bar still gets the click, so the items under a notice's wings keep theirs alone.
        let winged = Service()
        winged.notice = copied
        winged.syncScreenEdgeClicks()
        let wing = CGPoint(x: winged.geometry.screen.midX + 150, y: winged.geometry.screen.maxY)
        winged.handleScreenEdgeClick(.leftMouseDown, at: wing, isNotchWindow: false)
        winged.handleScreenEdgeClick(.leftMouseUp, at: wing, isNotchWindow: false)
        suite.expect(winged.screenEdgeClickArea?.width == winged.geometry.cameraWidth
                     && winged.screenEdgeClickArea?.midX == winged.geometry.screen.midX && winged.openings == 0,
                     "beside a camera a notice takes top-edge clicks over the camera only")
        winged.removeScreenEdgeClickMonitors()
        // A capsule leaves the menu bar above it to the island, end to end.
        let capsule = Service()
        capsule.geometry = NotchGeometry(screen: capsule.geometry.screen, safeAreaTop: 0, cameraWidth: 0,
                                         compactSideRoom: 160, silhouette: .capsule)
        capsule.notice = NotchNotice(event: .clipboard, title: "Copied a long title", detail: "A long copied text",
                                     symbol: "doc.on.clipboard")
        capsule.syncScreenEdgeClicks()
        let end = CGPoint(x: capsule.geometry.screen.midX + capsule.surfaceSize.width / 2 - NotchCapsuleLayout.side(capsule.geometry) - 1,
                          y: capsule.geometry.screen.maxY)
        capsule.handleScreenEdgeClick(.leftMouseDown, at: end, isNotchWindow: false)
        capsule.handleScreenEdgeClick(.leftMouseUp, at: end, isNotchWindow: false)
        suite.expect(capsule.openings == 1 && capsule.opened == .clipboard,
                     "a capsule's notice takes the menu bar's clicks along its whole width")
        capsule.removeScreenEdgeClickMonitors()
    }

    private static func menuBarEvent(_ type: NSEvent.EventType, at point: CGPoint) {
        for handler in Array(NSEvent.global.values) { handler(NSEvent(type, point: point)) }
    }

    private static func runReplacedNotices(_ suite: TestSuite) {
        let next = NotchNotice(event: .inputSource, title: "French", detail: "French", symbol: "keyboard")
        for expires in [false, true] {
            let service = Service()
            let top = CGPoint(x: service.geometry.screen.midX, y: service.geometry.screen.maxY)
            service.notice = layout
            service.syncScreenEdgeClicks()
            menuBarEvent(.leftMouseDown, at: top)
            service.notice = next
            service.syncScreenEdgeClicks()
            if expires { service.notice = nil; service.syncScreenEdgeClicks() }
            menuBarEvent(.leftMouseUp, at: top)
            suite.expect(service.openings == 0 && service.screenEdgePress == nil,
                         "a replacement cancels the old press even if the replacement also expires")
            if !expires {
                menuBarEvent(.leftMouseDown, at: top)
                menuBarEvent(.leftMouseUp, at: top)
                suite.expect(service.openings == 1 && service.opened == .controls && service.notice == nil,
                             "a new press opens where the replacement leads")
            }
            service.removeScreenEdgeClickMonitors()
        }
    }

    private static func runMenuClearance(_ suite: TestSuite) {
        for silhouette in [NotchSilhouette.capsule, .notch] {
            let service = Service()
            let screen = service.geometry.screen
            service.geometry = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, silhouette: silhouette)
            service.notice = layout
            let top = CGPoint(x: screen.midX, y: screen.maxY)
            let menu = CGRect(x: top.x - 10, y: top.y - 24, width: 20, height: 24)
            let blocked = NotchMenuBarLayout.sideRoom(screen: screen, cameraWidth: service.geometry.cameraWidth,
                                                      barHeight: 24, occupied: [menu])
            service.syncScreenEdgeClicks()
            suite.expect(blocked == nil && service.screenEdgeClickMonitors.isEmpty,
                         "a notice without a verified center leaves the top row with the menu")
            service.applyMenuSpace(0)
            menuBarEvent(.leftMouseDown, at: top)
            service.applyMenuSpace(blocked)
            suite.expect(service.screenEdgeClickMonitors.isEmpty && service.screenEdgePress == nil,
                         "a menu taking the simulated center cancels the press")
            service.applyMenuSpace(0)
            menuBarEvent(.leftMouseUp, at: top)
            suite.expect(service.openings == 0, "restoring clearance never rearms an interrupted press")
            menuBarEvent(.leftMouseDown, at: top)
            menuBarEvent(.leftMouseUp, at: top)
            suite.expect(service.openings == 1 && service.opened == .controls,
                         "a verified center takes a new click even with zero free room beside it")
            service.removeScreenEdgeClickMonitors()
        }
    }

    private static func runChangingNotices(_ suite: TestSuite) {
        let wing = Service()
        let top = CGPoint(x: wing.geometry.screen.midX, y: wing.geometry.screen.maxY)
        wing.geometry = NotchGeometry(screen: wing.geometry.screen, safeAreaTop: 32, cameraWidth: 180, compactSideRoom: 64)
        wing.syncScreenEdgeClicks()
        let beside = CGPoint(x: top.x + wing.geometry.cameraWidth / 2 + 8, y: top.y)
        menuBarEvent(.leftMouseDown, at: beside)
        wing.notice = layout
        wing.syncScreenEdgeClicks()
        menuBarEvent(.leftMouseUp, at: beside)
        suite.expect(wing.openings == 0 && wing.notice == layout, "a notice arriving under a resting wing leaves the release to the menu")
        menuBarEvent(.leftMouseDown, at: top)
        wing.notice = nil
        wing.routesNotices = false
        menuBarEvent(.leftMouseUp, at: top)
        suite.expect(wing.openings == 0, "turning the notice off during a press cancels its action")
        wing.removeScreenEdgeClickMonitors()

        for room in [CGFloat(0), 160] {
            let capsule = Service()
            capsule.geometry = NotchGeometry(screen: capsule.geometry.screen, safeAreaTop: 0, cameraWidth: 0,
                                             compactSideRoom: 160, silhouette: .capsule)
            capsule.notice = NotchNotice(event: .clipboard, title: "A long copied title that fills the capsule", detail: "Text",
                                         symbol: "doc.on.clipboard")
            let point = CGPoint(x: top.x + capsule.geometry.cameraWidth / 2 + 8, y: top.y)
            capsule.syncScreenEdgeClicks()
            menuBarEvent(.leftMouseDown, at: point)
            suite.expect(capsule.screenEdgePress != nil, "the wide notice took the original press")
            capsule.notice = nil
            capsule.applyMenuSpace(room)
            capsule.windowHost?.acceptsPoint = false
            menuBarEvent(.leftMouseUp, at: point)
            suite.expect(capsule.opened == (room == 0 ? nil : .clipboard),
                         "a capsule shrinking under a stationary press keeps its action only while the menu bar still has room")
            capsule.removeScreenEdgeClickMonitors()
        }
    }
}
