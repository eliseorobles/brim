// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Carbon.HIToolbox

/// Production opening and availability methods run with inert presentation
/// doubles. Feature choices live only in a disposable test preferences domain.
enum NotchDestinationContract {
    enum ReviewDefaults { static var current: UserDefaults! }
    enum NotchContentTransition { case none, reveal, replace }
    /// Like AppKit while Brim stays active, makeKey and resignKey leave
    /// the app's key window as it was; tests set that record by hand.
    final class Panel {
        var isKeyWindow = true
        var acceptsKeyFocus = false
        var isVisible = true
        var isOnActiveSpace = true
        var canBecomeMain = false
        var keyRequests = 0
        func makeKey() { keyRequests += 1 }
        func resignKey() { isKeyWindow = false }
    }
    enum NSWorkspace { static let shared = Workspace() }
    final class Workspace { var frontmostApplication: RunningApplication? }
    struct RunningApplication { let processIdentifier: Int32 }
    final class Host { func containsHover(_ point: CGPoint) -> Bool { false } }
    enum NSEvent { static let mouseLocation = CGPoint.zero }
    final class AppDelegate { func closePopover(preservingNotch: Bool) {} }
    final class Application {
        let delegate: AnyObject? = nil
        var keyWindow: Panel?
        var orderedWindows: [Panel] = []
    }
    static let NSApp = Application()
    enum ClipboardHistoryService {
        static let shared = Reader()
        struct Reader { func rememberPasteTarget() {} }
    }
    enum MenuPanelFocus {
        static let shared = Focus()
        final class Focus {
            var normalRequests = 0
            func showNormalPanel() { normalRequests += 1 }
        }
    }
    final class LockScreen {
        var syncs: [NotchSessionState] = []
        var sounds: [Bool] = []
        var onSync: (() -> Void)?
        func sync(_ session: NotchSessionState) { syncs.append(session); onSync?() }
        func playSound(locking: Bool) { sounds.append(locking) }
    }
    enum NotchLockScreenService { static var shared = LockScreen() }
    final class Hotkey {
        var onPress: (() -> Void)?
        var refuses = false
        var requests: [Bool] = []
        func sync(enabled: Bool, shortcut: GlobalShortcut, storageKey: String) -> Bool {
            requests.append(enabled)
            return !(enabled && refuses)
        }
    }
    enum ShortcutCapture { static var isCapturing = false }

    class State {
        var acceptsUserInteraction = true
        func collapse() { expanded = false }
        var hiddenInFullscreen = false
        var running = true
        var session = NotchSessionState()
        var suspended: Bool { !session.canPresent }
        var panel: Panel? = Panel()
        var windowHost: Host? = Host()
        var modules: [NotchModule] = []
        var selected = NotchModule.controls
        var selectedMetric: MetricDetailKind?
        var expanded = false
        var showsKeyboardFocus = false
        var showingAppPanel = false
        var showingSections = false
        var sectionQuery = ""
        var sectionRow = 0
        var highlightedSection: NotchModule?
        var peeking = false
        var pinned = false
        var openedByHover = false
        var inside = false
        var notice: NotchNotice?
        var compactActivity: NotchCompactActivity?
        var hoverState = NotchHoverState()
        var hoverWork: DispatchWorkItem?
        var requestedDetail: MetricDetailKind?
        var detailHasPage = false
        var pageLayers: [NotchModule: () -> Void] = [:]
        var presentationSyncs = 0
        var presentationTearDowns = 0
        func mutatePresentation(transitionContent: NotchContentTransition, _ change: () -> Void) { change() }
        func installEventMonitors() {}
        func syncVisibleConsumers() { requestedDetail = selectedMetric }
        func provideHapticFeedback() {}
        let hotkey = Hotkey()
        var shortcutFailureWrites = 0
        var shortcutRegistrationFailed = false { didSet { shortcutFailureWrites += 1 } }
        func tearDownPresentation() { expanded = false; presentationTearDowns += 1 }
    }

    static func run(_ suite: TestSuite) {
        let domain = "brim.tests.notch-destinations"
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
        // The AI agents page, which the agents activity opens, is opt-in.
        defaults.set(true, forKey: DefaultsKey.notchAgentsEnabled)
        let focus = Service()
        focus.showsKeyboardFocus = true
        focus.open(.controls)
        suite.expect(!focus.showsKeyboardFocus, "reopening the island clears the previous automatic focus indicator")
        focus.showsKeyboardFocus = true
        focus.open(.clipboard)
        suite.expect(focus.showsKeyboardFocus, "changing pages in the open island preserves keyboard focus visibility")
        focus.collapse()
        focus.open(.controls, takeFocus: false)
        suite.expect(!focus.showsKeyboardFocus, "hover opening starts without an automatic focus indicator")
        keyHandoffContracts(suite: suite)
        reopeningContracts(defaults: defaults, suite: suite)
        stepBackContracts(suite)
        let families: [(MetricDetailKind, AppFeature)] = [
            (.cpu, .monitorCPU), (.gpu, .monitorGPU), (.memory, .monitorMemory),
            (.network, .monitorNetwork), (.disk, .monitorDisk),
            (.battery, .monitorPower), (.power, .monitorPower), (.fan, .fanControl),
            (.connectedDevices, .connectedDevices),
        ]
        for (metric, feature) in families {
            let service = Service()
            service.open(.system, pinned: true, metric: metric)
            suite.expect(service.selectedMetric == metric, "an available metric opens its own detail")
            defaults.set(false, forKey: feature.availabilityKey)
            service.syncWithPreferences()
            suite.expect(service.selectedMetric == nil && service.requestedDetail == nil,
                   "removing the selected metric clears its detail even when other system families remain")
            service.open(.system, metric: metric, sections: true)
            service.open(.system, metric: metric)
            suite.expect(service.selectedMetric == nil,
                   "a retained gallery argument cannot restore a metric removed from the hub")
            defaults.set(true, forKey: feature.availabilityKey)
        }
        let service = Service()
        service.open(.system, metric: .cpu)
        for (_, feature) in families { defaults.set(false, forKey: feature.availabilityKey) }
        service.syncWithPreferences()
        suite.expect(!service.modules.contains(.system) && service.selected == .controls
               && service.selectedMetric == nil && service.requestedDetail == nil,
               "removing the last system family selects an available module without keeping its old detail")
        defaults.set(true, forKey: AppFeature.fanControl.availabilityKey)
        service.open(.system, metric: .fan)
        suite.expect(service.modules.contains(.system) && service.selectedMetric == .fan,
               "a separately installed fan feature exposes System and retains its direct detail")
        sessionContracts(suite)
        lockScreenContracts(defaults: defaults, suite: suite)
        shortcutContracts(defaults: defaults, suite: suite)
    }

    /// Escape steps back through what the island shows, then closes it.
    private static func stepBackContracts(_ suite: TestSuite) {
        let metric = Service()
        metric.open(.system)
        metric.open(.system, metric: .cpu)
        metric.stepBack()
        suite.expect(metric.expanded && metric.selected == .system && metric.selectedMetric == nil,
                     "Escape steps back from a detail opened on its page, as the Back button does")
        metric.stepBack()
        suite.expect(!metric.expanded, "Escape closes the island once nothing lies behind the page")

        let panel = Service()
        panel.open(.clipboard)
        panel.open(.controls, appPanel: true)
        panel.stepBack()
        suite.expect(panel.expanded && panel.selected == .controls && !panel.showingAppPanel,
                     "Escape steps back from the app panel opened inside the island")

        // Closing passes for any page, so these first check a detail is open.
        for appPanel in [false, true] {
            let direct = Service()
            direct.open(appPanel ? .controls : .system, appPanel: appPanel, metric: appPanel ? nil : .cpu)
            let detail = direct.showingAppPanel || direct.selectedMetric == .cpu
            direct.stepBack()
            suite.expect(detail && !direct.expanded,
                         "a detail the island opened on closes on Escape like the menu panel (app panel: \(appPanel))")
        }

        for route in ["a metric", "the app panel"] {
            let menuBar = Service()
            menuBar.open(.clipboard)
            if route == "a metric" { menuBar.showMetric(.cpu, toggle: true) } else { menuBar.openAppPanel(toggle: true) }
            let detail = menuBar.selectedMetric == .cpu || menuBar.showingAppPanel
            menuBar.stepBack()
            suite.expect(detail && !menuBar.expanded,
                         "\(route) opened from the menu bar over an open island closes on Escape like the menu panel")
        }
        let tile = Service()
        tile.open(.system)
        tile.showMetric(.cpu)
        tile.stepBack()
        suite.expect(tile.expanded && tile.selected == .system && tile.selectedMetric == nil,
                     "a metric opened from its tile inside the island steps back to the page")

        let switched = Service()
        switched.open(.system, metric: .cpu)
        switched.toggleSections()
        switched.toggleSections()
        switched.open(.system, metric: .memory)
        let switchedDetail = switched.selectedMetric == .memory && !switched.showingSections
        switched.stepBack()
        suite.expect(switchedDetail && !switched.expanded,
                     "passing through the gallery or switching details keeps a direct detail closing on Escape")

        let gallery = Service()
        gallery.open(.system)
        gallery.open(.system, metric: .cpu)
        gallery.toggleSections()
        gallery.toggleSections()
        gallery.stepBack()
        suite.expect(gallery.expanded && gallery.selected == .system && gallery.selectedMetric == nil,
                     "the gallery opened over a detail keeps its way back to the page")

        let reopened = Service()
        reopened.open(.system)
        reopened.open(.system, metric: .cpu)
        // Closing the island keeps its detail.
        reopened.expanded = false
        reopened.open(.system, metric: .cpu)
        let reopenedDetail = reopened.expanded && reopened.selectedMetric == .cpu
        reopened.stepBack()
        suite.expect(reopenedDetail && !reopened.expanded, "a detail the island reopens on has nothing behind it")

        var closes: [NotchModule] = []
        let layered = Service()
        layered.open(.clipboard)
        layered.setPageLayer(.clipboard) { closes.append(.clipboard); layered.setPageLayer(.clipboard, close: nil) }
        layered.setPageLayer(.agents) { closes.append(.agents) }
        layered.stepBack()
        suite.expect(layered.expanded && closes == [.clipboard], "Escape closes the page's own layer before the island")
        layered.stepBack()
        suite.expect(!layered.expanded && closes == [.clipboard], "only the visible page's layer answers Escape")

        let covered = Service()
        covered.open(.system)
        covered.setPageLayer(.system) { closes.append(.system) }
        covered.open(.system, metric: .cpu)
        covered.stepBack()
        suite.expect(covered.selectedMetric == nil && closes == [.clipboard],
                     "a detail steps back before a layer of the page it covers")

    }

    /// The island resigns by hand while it stays on screen. The keyboard goes
    /// back to a regular Brim window only while Brim is in front.
    private static func keyHandoffContracts(suite: TestSuite) {
        let brim = RunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        /// Returns the windows that were made key, front to back.
        func handoff(frontmost: RunningApplication?, keyIsPanel: Bool = true, settingsVisible: Bool = true,
                     settingsIsRegular: Bool = true, otherSpaceInFront: Bool = false,
                     regularBehind: Bool = false) -> [String] {
            let service = Service()
            guard let panel = service.panel else { return ["no panel"] }
            let hidden = Panel(), otherSpace = Panel(), helper = Panel(), settings = Panel(), behind = Panel()
            for window in [hidden, otherSpace, behind] { window.canBecomeMain = true }
            hidden.isVisible = false
            otherSpace.isOnActiveSpace = false
            settings.canBecomeMain = settingsIsRegular
            settings.isVisible = settingsVisible
            let named = [("hidden", hidden), ("other Space", otherSpace), ("helper", helper),
                         ("settings", settings), ("behind", behind)]
                .filter { $0.0 != "other Space" || otherSpaceInFront }
                .filter { $0.0 != "behind" || regularBehind }
            NSApp.orderedWindows = [panel] + named.map(\.1)
            NSApp.keyWindow = keyIsPanel ? panel : nil
            NSWorkspace.shared.frontmostApplication = frontmost
            service.resignPanelKey()
            defer {
                NSApp.orderedWindows = []
                NSApp.keyWindow = nil
                NSWorkspace.shared.frontmostApplication = nil
            }
            guard !panel.isKeyWindow else { return ["island"] }
            return named.flatMap { name, window in Array(repeating: name, count: window.keyRequests) }
        }
        suite.expect(handoff(frontmost: brim) == ["settings"],
                     "closing the island hands the keyboard back to Settings while Brim stays active")
        suite.expect(handoff(frontmost: brim, otherSpaceInFront: true, regularBehind: true) == ["settings"],
                     "closing the island hands the keyboard to the frontmost regular window on this Space")
        suite.expect(handoff(frontmost: RunningApplication(processIdentifier: 1)).isEmpty,
                     "closing the island leaves the keyboard alone while another app takes over")
        suite.expect(handoff(frontmost: brim, keyIsPanel: false).isEmpty,
                     "closing the island hands nothing over once AppKit has let it go")
        suite.expect(handoff(frontmost: brim, settingsVisible: false).isEmpty
                     && handoff(frontmost: brim, settingsIsRegular: false).isEmpty,
                     "closing the island hands the keyboard only to a visible regular window")
    }

    private static func reopeningContracts(defaults: UserDefaults, suite: TestSuite) {
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchReturnHome] as? Bool == false,
               "returning home is opt-in and preserves the existing opening behavior")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchHomeModule] as? String == NotchModule.controls.rawValue,
               "the previously available home option keeps Controls as its initial destination")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchOpensActivity] as? Bool == true,
               "opening the visible activity stays the default")
        for returnHome in [false, true] {
            defaults.set(returnHome, forKey: DefaultsKey.notchReturnHome)
            let service = Service()
            service.open(.clipboard)
            service.open()
            suite.expect(service.selected == .clipboard, "an already open island does not jump away from the current page")
            service.expanded = false
            service.open()
            suite.expect(service.selected == (returnHome ? .controls : .clipboard),
                   "reopening either restores the last page or returns home according to the preference")
            service.expanded = false
            service.open(.agents)
            suite.expect(service.selected == .agents, "an explicit destination always wins over the opening preference")
            defaults.set("controls", forKey: DefaultsKey.notchHiddenModules)
            defaults.set("clipboard,agents", forKey: DefaultsKey.notchModuleOrder)
            service.expanded = false
            service.open()
            suite.expect(service.selected == (returnHome ? .clipboard : .agents),
                   "a hidden home page falls back to the first visible page without unhiding controls")
            defaults.set("", forKey: DefaultsKey.notchHiddenModules)
            defaults.set("", forKey: DefaultsKey.notchModuleOrder)
        }
        defaults.set(true, forKey: DefaultsKey.notchReturnHome)
        for page in NotchSupport.modules(in: defaults) {
            defaults.set(page.rawValue, forKey: DefaultsKey.notchHomeModule)
            let service = Service()
            service.open()
            suite.expect(service.selected == page, "each available page can be chosen for reopening: \(page.rawValue)")
            service.open(.clipboard)
            suite.expect(service.selected == .clipboard, "a saved opening page never overrides explicit navigation")
            defaults.set(page.rawValue, forKey: DefaultsKey.notchHiddenModules)
            service.expanded = false
            service.open()
            suite.expect(service.selected == NotchSupport.modules(in: defaults).first,
                   "hiding the saved opening page falls back to an available page")
            defaults.set("", forKey: DefaultsKey.notchHiddenModules)
        }
        for destination in NotchReopeningDestination.allCases {
            defaults.set(destination.rawValue, forKey: DefaultsKey.notchHomeModule)
            let service = Service()
            service.open(.clipboard)
            service.expanded = false
            let focusRequests = MenuPanelFocus.shared.normalRequests
            service.open()
            suite.expect(service.showingAppPanel == (destination == .appPanel)
                   && service.showingSections == (destination == .explore),
                   "reopening shows the selected app panel or Explore destination")
            if destination == .explore {
                suite.expect(service.highlightedSection == .clipboard && service.sectionQuery.isEmpty,
                       "reopening Explore highlights its current page for keyboard navigation")
            }
            suite.expect(MenuPanelFocus.shared.normalRequests - focusRequests == (destination == .appPanel ? 1 : 0),
                   "only opening the app panel resets its panel focus")
            service.expanded = false
            service.open(.agents)
            suite.expect(service.selected == .agents && !service.showingAppPanel && !service.showingSections,
                   "explicit page navigation wins over a saved app panel or Explore destination")

            service.expanded = false
            service.compactActivity = .agents
            service.open(.clipboard)
            service.expanded = false
            service.open()
            suite.expect(service.selected == .agents && !service.showingAppPanel && !service.showingSections,
                   "a visible activity wins over a saved app panel or Explore destination")

            defaults.set(false, forKey: DefaultsKey.notchOpensActivity)
            service.expanded = false
            service.open()
            suite.expect(service.showingAppPanel == (destination == .appPanel)
                   && service.showingSections == (destination == .explore),
                   "with activities turned off, a visible activity leaves the saved app panel or Explore destination")
            service.expanded = false
            service.openActivity(.agents)
            suite.expect(service.showingAppPanel == (destination == .appPanel)
                   && service.showingSections == (destination == .explore),
                   "with activities turned off, a tap on the activity's strip follows the reopening choice too")
            defaults.set(true, forKey: DefaultsKey.notchOpensActivity)
            service.expanded = false
            service.openActivity(.agents)
            suite.expect(service.selected == .agents && !service.showingAppPanel && !service.showingSections,
                   "a tap on the activity's strip opens its page while activities open")
        }
        defaults.set("unknown-page", forKey: DefaultsKey.notchHomeModule)
        let invalid = Service()
        invalid.open()
        suite.expect(invalid.selected == .controls, "a malformed saved page falls back to Controls")
        defaults.set(NotchModule.controls.rawValue, forKey: DefaultsKey.notchHomeModule)
        defaults.set(false, forKey: DefaultsKey.notchReturnHome)
        activityContracts(defaults: defaults) { suite.expect($0, $1) }
    }

    /// What the closed island is already showing is what opening it shows,
    /// unless the user turned that off for activities.
    private static func activityContracts(defaults: UserDefaults, expect: (Bool, String) -> Void) {
        for returnHome in [false, true] {
            defaults.set(returnHome, forKey: DefaultsKey.notchReturnHome)
            defaults.set(NotchModule.controls.rawValue, forKey: DefaultsKey.notchHomeModule)
            for activity in [NotchCompactActivity.agents, .keepAwake] {
                let service = Service()
                service.open(.clipboard)
                service.expanded = false
                service.compactActivity = activity
                expect(service.reopeningModule == activity.module, "a visible activity is what a peek names before opening")
                service.open()
                expect(service.selected == activity.module,
                       "hovering or clicking an island that shows \(activity) opens that activity, not the reopening page")
                service.open()
                expect(service.selected == activity.module, "an already open island stays on the activity's page")
                service.open(.clipboard)
                expect(service.selected == .clipboard, "an explicit page still wins over the visible activity")
                service.expanded = false
                service.compactActivity = nil
                service.open()
                expect(service.selected == (returnHome ? .controls : .clipboard),
                       "once the activity ends, reopening follows the saved preference again")

                defaults.set(false, forKey: DefaultsKey.notchOpensActivity)
                service.open(.clipboard)
                service.expanded = false
                service.compactActivity = activity
                expect(service.reopeningModule == (returnHome ? .controls : .clipboard),
                       "with activities turned off, a peek over \(activity) names the reopening page")
                service.open()
                expect(service.selected == (returnHome ? .controls : .clipboard),
                       "with activities turned off, opening an island that shows \(activity) follows the saved preference")
                service.open(activity.module)
                expect(service.selected == activity.module,
                       "with activities turned off, the page of \(activity) still opens when named")
                defaults.set(true, forKey: DefaultsKey.notchOpensActivity)
            }
            let hidden = Service()
            defaults.set("agents", forKey: DefaultsKey.notchHiddenModules)
            hidden.syncWithPreferences()
            hidden.compactActivity = .agents
            hidden.open()
            expect(hidden.selected == .controls && !hidden.modules.contains(.agents),
                   "an activity whose page is hidden cannot open it and falls back to the reopening rule")
            defaults.set("", forKey: DefaultsKey.notchHiddenModules)

            let feedback = Service()
            feedback.notice = NotchNotice(event: .inputSource, title: "ABC", detail: "ABC", symbol: "keyboard")
            feedback.open()
            expect(feedback.notice != nil && feedback.selected == .controls,
                   "system feedback keeps its own timer and never redirects an opening")
        }
        defaults.set(false, forKey: DefaultsKey.notchReturnHome)
    }

    /// The lock screen follows the island's own teardown, so what it starts is
    /// never stopped under it. On unlock it starts leaving before the island
    /// returns and stops nothing the island takes back. The padlock plays only
    /// for a lock or unlock made at the Mac.
    private static func lockScreenContracts(defaults: UserDefaults, suite: TestSuite) {
        defer {
            NotchLockScreenService.shared = LockScreen()
            defaults.set(false, forKey: DefaultsKey.notchLockSounds)
        }
        let service = Service()
        let lockScreen = LockScreen()
        NotchLockScreenService.shared = lockScreen
        var order: [String] = []
        lockScreen.onSync = { order.append("sync after \(service.presentationTearDowns) teardowns, \(service.presentationSyncs) returns") }
        defaults.set(true, forKey: DefaultsKey.notchLockSounds)
        service.updateSession { $0.locked = true }
        suite.expect(order == ["sync after 1 teardowns, 0 returns"] && lockScreen.syncs.last?.showsLockScreen == true,
                     "the lock screen takes over after the island has stopped its own sources")
        service.updateSession { $0.locked = false }
        // The first sync is the scene leaving: canPresent tells it to stop
        // none of the sources the island is about to take back.
        suite.expect(order == ["sync after 1 teardowns, 0 returns", "sync after 1 teardowns, 0 returns",
                               "sync after 1 teardowns, 1 returns"]
                     && lockScreen.syncs.count == 3 && lockScreen.syncs.dropFirst().allSatisfy { !$0.locked && $0.canPresent },
                     "on unlock the lock screen starts leaving before the island returns and stops nothing it takes back")
        suite.expect(lockScreen.sounds == [true, false], "locking and unlocking at the Mac each play their padlock")
        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.locked = true }
        suite.expect(lockScreen.sounds == [true, false] && lockScreen.syncs.last?.showsLockScreen == false,
                     "a lock that comes with a dark display plays nothing and shows nothing")
        service.updateSession { $0.displaysSleeping = false }
        suite.expect(lockScreen.syncs.last?.showsLockScreen == true, "waking the display shows the lock screen")
        service.updateSession { $0.screenSaverRunning = true }
        suite.expect(lockScreen.syncs.last?.showsLockScreen == false && lockScreen.sounds.count == 2,
                     "a screen saver hides the lock screen without a sound")
        service.updateSession { $0.screenSaverRunning = false }
        defaults.set(false, forKey: DefaultsKey.notchLockSounds)
        service.updateSession { $0.locked = false }
        suite.expect(lockScreen.sounds.count == 2, "with the sounds off, unlocking is silent")
        defaults.set(true, forKey: DefaultsKey.notchLockSounds)
        service.updateSession { $0.locked = true }
        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.locked = false }
        service.updateSession { $0.displaysSleeping = false }
        suite.expect(lockScreen.sounds == [true, false, true, false],
                     "an unlock announced before the display wakes still plays its padlock")
        service.running = false
        let syncs = lockScreen.syncs.count
        service.updateSession { $0.locked = true }
        suite.expect(lockScreen.syncs.count == syncs && lockScreen.sounds.count == 4,
                     "a stopped island leaves the lock screen alone")
    }

    private static func sessionContracts(_ suite: TestSuite) {
        let service = Service()
        service.updateSession { $0.displaysSleeping = true }
        suite.expect(service.presentationTearDowns == 1 && !service.session.canPresent,
               "display sleep removes presentation")
        service.updateSession { $0.sleeping = true }
        suite.expect(service.presentationTearDowns == 1,
               "system sleep after the display already hid the island tears nothing down again")
        service.updateSession { $0.locked = true }
        service.updateSession { $0.displaysSleeping = false }
        service.updateSession { $0.sleeping = false }
        suite.expect(service.presentationSyncs == 0,
               "display and system wake cannot resume presentation while the session is locked")
        service.updateSession { $0.locked = false }
        suite.expect(service.presentationSyncs == 1,
               "unlocking after every sleep condition clears resumes through the normal presentation path once")

        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.onConsole = false }
        service.updateSession { $0.onConsole = true }
        suite.expect(service.presentationSyncs == 1 && !service.session.canPresent,
               "returning to the same session leaves the island away while its display remains asleep")
        service.updateSession { $0.displaysSleeping = false }
        suite.expect(service.presentationSyncs == 2, "the island returns only after the display also wakes")
        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.locked = true }
        service.updateSession { $0.onConsole = false }
        service.updateSession { $0.locked = false }
        service.updateSession { $0.displaysSleeping = false }
        suite.expect(service.presentationSyncs == 2,
               "unlock and display wake cannot resume presentation while another login session owns the console")
        service.running = false
        service.updateSession { $0.onConsole = true }
        suite.expect(service.presentationSyncs == 2, "late session notifications cannot restart a stopped island")
    }

    /// Like a click on the closed island, the shortcut toggles the island. It
    /// holds its key only while it is on and no other shortcut is recording.
    private static func shortcutContracts(defaults: UserDefaults, suite: TestSuite) {
        defer {
            ShortcutCapture.isCapturing = false
            defaults.set(false, forKey: DefaultsKey.notchShortcutEnabled)
        }
        func pressed(interactive: Bool = true, presses: Int = 1) -> Service {
            let service = Service()
            service.installHotkey()
            service.acceptsUserInteraction = interactive
            for _ in 0..<presses { service.hotkey.onPress?() }
            return service
        }
        suite.expect(!pressed(interactive: false).expanded,
                     "the island shortcut does nothing while the island does not accept user interaction")
        suite.expect(pressed().expanded && !pressed(presses: 2).expanded,
                     "the island shortcut opens the island and a second press closes it")

        let registration = Service()
        defaults.set(true, forKey: DefaultsKey.notchShortcutEnabled)
        registration.syncShortcut()
        ShortcutCapture.isCapturing = true
        registration.syncShortcut()
        ShortcutCapture.isCapturing = false
        registration.syncShortcut()
        defaults.set(false, forKey: DefaultsKey.notchShortcutEnabled)
        registration.syncShortcut()
        suite.expect(registration.hotkey.requests == [true, false, true, false],
                     "the island shortcut lets its key go while another shortcut is recording and while it is off")
        let refused = Service()
        refused.hotkey.refuses = true
        defaults.set(true, forKey: DefaultsKey.notchShortcutEnabled)
        refused.syncShortcut()
        refused.syncShortcut()
        let failed = refused.shortcutRegistrationFailed
        defaults.set(false, forKey: DefaultsKey.notchShortcutEnabled)
        refused.syncShortcut()
        refused.syncShortcut()
        suite.expect(failed && !refused.shortcutRegistrationFailed && refused.shortcutFailureWrites == 2,
                     "a refused island shortcut reports the failure and its end once each, not on every sync")
    }
}
