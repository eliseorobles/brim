// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The production closed surface and the monitor demand it makes, run with
/// controlled activities, notices and preferences. Nothing is shown.
enum NotchVisibilityTests {
    enum ReviewDefaults { static var current: UserDefaults! }
    enum PowerSampler { static var hasInternalBattery = true }
    struct MonitorNeeds {
        var disk = false
        var fanSpeed = false
        var connectedDevices = false
        static let none = Self()
    }
    struct Metric { let monitorNeeds = MonitorNeeds.none }
    final class SystemMonitor {
        static let shared = SystemMonitor()
        var detailNeeds = MonitorNeeds.none
        var visible = false
        func setNotchDetailNeeds(_ needs: MonitorNeeds) { detailNeeds = needs }
        func setNotchVisible(_ visible: Bool) { self.visible = visible }
    }

    class State {
        var activitySelection = NotchActivitySelection()
        var inside = false
        var hiddenInFullscreen = false
        var running = true, suspended = false
        var expanded = false, peeking = false
        var showingAppPanel = false, showingSections = false
        var selected = NotchModule.controls
        var selectedMetric: Metric?
        var modules: [NotchModule] = []
        var notice: NotchNotice?
        var hasAgentActivity = false, hasKeepAwakeActivity = false
        var agentStripWing: CGFloat = 58
        func agentStripWing(in geometry: NotchGeometry) -> CGFloat { agentStripWing }
        var keepAwakeStripWing: CGFloat = 50
        func keepAwakeStripWing(in geometry: NotchGeometry) -> CGFloat { keepAwakeStripWing }
        var notchNeedsMonitor = false
        var hoverEmphasized = false
        var geometry = NotchGeometry(screen: NotchVisibilityTests.screen, safeAreaTop: 32, cameraWidth: 180,
                                     menuBarHeight: 32, compactSideRoom: 100)
        var expandedSize: CGSize { geometry.expanded }
        var capsuleSurfaceSize: CGSize? { nil }
        var compactActivityPickerLayout = NotchActivityPickerLayout(
            count: 2, labelWidth: 80, stripSize: CGSize(width: 300, height: 32), screenWidth: 1470)
        func syncMenuSpaceMonitoring() {}
    }

    static let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)

    static func run(_ suite: TestSuite) {
        let domain = "brim.tests.notch-visibility"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        ReviewDefaults.current = defaults
        defer {
            ReviewDefaults.current = nil
            defaults.removePersistentDomain(forName: domain)
        }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { defaults.set(value, forKey: key) }
        for feature in AppFeature.allCases { defaults.set(true, forKey: feature.availabilityKey) }
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        monitorContracts(defaults: defaults, suite: suite)
        activityContracts(suite)
        noticeContracts(suite)
        fullscreenContracts(suite)
        hiddenContracts(defaults: defaults, suite: suite)
    }

    private static func monitorContracts(defaults: UserDefaults, suite: TestSuite) {
        let devices = Service()
        devices.modules = [.system]
        devices.selected = .system
        defaults.set(false, forKey: DefaultsKey.menuBarConnectedDevices)
        for installed in [true, false] {
            defaults.set(installed, forKey: AppFeature.connectedDevices.availabilityKey)
            for expanded in [true, false] {
                for showingSections in [true, false] {
                    devices.expanded = expanded
                    devices.showingSections = showingSections
                    devices.syncVisibleConsumers()
                    suite.expect(SystemMonitor.shared.detailNeeds.connectedDevices == (installed && expanded && !showingSections),
                                 "USB sampling follows the visible System page and installed feature, independently of its widget")
                }
            }
        }
        defaults.set(true, forKey: AppFeature.connectedDevices.availabilityKey)
        devices.expanded = true
        devices.showingSections = false
        devices.syncVisibleConsumers()
        suite.expect(devices.notchNeedsMonitor && SystemMonitor.shared.visible,
                     "the open System page asks the monitor to sample")
        devices.suspended = true
        devices.syncVisibleConsumers()
        suite.expect(!devices.notchNeedsMonitor && !SystemMonitor.shared.visible
                     && !SystemMonitor.shared.detailNeeds.connectedDevices,
                     "a suspended island releases its sampling demand")
        devices.suspended = false
        devices.syncVisibleConsumers()
        devices.releaseMonitor()
        suite.expect(!devices.notchNeedsMonitor && !SystemMonitor.shared.visible
                     && !SystemMonitor.shared.detailNeeds.connectedDevices,
                     "releasing the island stops its connected device sampling demand")
    }

    private static func activityContracts(_ suite: TestSuite) {
        let service = Service()
        suite.expect(service.compactActivity == nil, "with nothing running the closed island shows no activity")
        service.hasKeepAwakeActivity = true
        suite.expect(service.compactActivity == .keepAwake
                     && service.compactActivityGeometry
                        == service.geometry.compactKeepAwakeGeometry(wing: service.keepAwakeStripWing)
                     && service.surfaceSize == service.compactActivityGeometry.compactActivitySize
                     && service.surfaceSize.width > service.geometry.cameraWidth,
                     "a running Keep Awake session takes its own wings beside the camera")
        service.hasAgentActivity = true
        suite.expect(service.compactActivity == .agents
                     && service.compactActivityGeometry == service.geometry.compactAgentGeometry(wing: service.agentStripWing)
                     && service.surfaceSize == service.compactActivityGeometry.compactActivitySize,
                     "a working agent comes first, in its own wings")
        service.activitySelection.select(.keepAwake, available: service.compactActivities)
        suite.expect(service.compactActivity == .keepAwake, "the chosen activity stays in front while both run")
        service.hasKeepAwakeActivity = false
        suite.expect(service.compactActivity == .agents, "the other activity shows once the chosen one ends")
        service.hoverEmphasized = true
        suite.expect(service.surfaceSize == NotchHoverEmphasis.size(from: service.compactActivityGeometry.compactActivitySize,
                                                                    geometry: service.geometry),
                     "the hover emphasis grows around the activity's strip")
        service.hoverEmphasized = false
        service.hasKeepAwakeActivity = true
        service.inside = true
        suite.expect(service.showsCompactActivityPicker && service.surfaceSize == service.compactActivityPickerLayout.size,
                     "with two activities running, the pointer on the island offers the choice between them")
        service.hasKeepAwakeActivity = false
        suite.expect(!service.showsCompactActivityPicker, "a single activity offers no choice")
    }

    private static func noticeContracts(_ suite: TestSuite) {
        let service = Service()
        service.geometry = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 180, menuBarHeight: 32,
                                         compactSideRoom: 300)
        service.hasKeepAwakeActivity = true
        let notice = NotchNotice(event: .inputSource, title: "ABC", detail: "U.S. International – PC", symbol: "keyboard")
        let wings = notice.wings(in: service.geometry)
        service.notice = notice
        suite.expect(service.surfaceSize == service.geometry.noticeSize(wings: wings)
                     && service.surfaceSize.width > service.geometry.notice.width
                     && service.surfaceShift == service.geometry.noticeShift(wings) && service.surfaceShift > 0,
                     "a notice widens the actual presentation toward its longer side")
        service.expanded = true
        suite.expect(service.surfaceShift == 0 && service.surfaceSize == service.expandedSize,
                     "the open island stays on the camera's centre")
        service.expanded = false
        service.notice = nil
        suite.expect(service.surfaceShift == 0 && service.surfaceSize == service.compactActivityGeometry.compactActivitySize,
                     "once the notice ends the island returns to the camera's centre and the activity's width")
    }

    private static func fullscreenContracts(_ suite: TestSuite) {
        for physical in [true, false] {
            let service = Service()
            service.geometry = NotchGeometry(screen: screen, safeAreaTop: physical ? 32 : 0,
                                             cameraWidth: physical ? 180 : 0, menuBarHeight: 32, compactSideRoom: 100)
            let closed = service.geometry.restingSize(showsContent: false)
            service.hasKeepAwakeActivity = true
            suite.expect(service.surfaceSize.width > closed.width, "precondition: the activity widens the closed island")
            service.hiddenInFullscreen = true
            suite.expect(service.fullscreenCompact && service.surfaceSize == closed,
                         "fullscreen keeps a black cutout over a running activity")
            service.geometry = NotchGeometry(screen: screen, safeAreaTop: physical ? 32 : 0,
                                             cameraWidth: physical ? 180 : 0, menuBarHeight: 32, compactSideRoom: 100,
                                             outline: true)
            suite.expect(service.surfaceSize == closed,
                         "fullscreen draws no outline, so its cutout keeps to the camera without the outline's room")
            service.expanded = true
            suite.expect(!service.fullscreenCompact && service.surfaceSize == service.expandedSize,
                         "opening the island in fullscreen shows its page")
        }
    }

    private static func hiddenContracts(defaults: UserDefaults, suite: TestSuite) {
        defer {
            for key in [DefaultsKey.notchHideUntilHover, DefaultsKey.notchOpenOnHover, DefaultsKey.notchHiddenShowsActivity] {
                defaults.set(Defaults.registeredDefaults[key], forKey: key)
            }
        }
        defaults.set(true, forKey: DefaultsKey.notchHideUntilHover)
        defaults.set(true, forKey: DefaultsKey.notchOpenOnHover)
        defaults.set(false, forKey: DefaultsKey.notchHiddenShowsActivity)
        let service = Service()
        service.inside = true
        service.hasAgentActivity = true
        service.hasKeepAwakeActivity = true
        suite.expect(!service.showsCompactActivityPicker, "an island hidden until hover stays out of sight with activities")
        defaults.set(true, forKey: DefaultsKey.notchHiddenShowsActivity)
        suite.expect(service.showsCompactActivityPicker,
                     "set to show activity, a hidden island with activities comes into sight and offers the choice")
        service.geometry = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0)
        suite.expect(!service.showsCompactActivityPicker,
                     "beside a simulated cutout with no room from the menus, a hidden island keeps waiting for the pointer")
    }
}
