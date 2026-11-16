// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Combine
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import VMStatisticsCompat

enum SettingsFeatureTests {
    /// The island settings view, around its production reveal.
    final class IslandSettings {
        let router: SettingsRouter
        var tab = NotchSettingsTab.layout
        var selectedModule = NotchModule.controls

        init(router: SettingsRouter) { self.router = router }
    }

    private static func search(_ suite: TestSuite) {
        let domain = "brim.tests.settings-search." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.setPersistentDomain([
            DefaultsKey.notchIdleContent: NotchIdleContent.battery.rawValue,
            DefaultsKey.notchLowBatteryTint: true, DefaultsKey.notchLowBatteryEarly: true,
            DefaultsKey.notchAgentsLiveActivity: true,
            DefaultsKey.notchClipboardWindow: true, DefaultsKey.monitorAlertDisk: true,
            DefaultsKey.monitorAlertBattery: true, DefaultsKey.monitorAlertBatteryTemperature: true,
        ], forName: domain)

        func state(battery: Bool = true) -> SettingsSearchState {
            SettingsSearchState(defaults: defaults, hardware: .init(
                battery: battery, notchedDisplay: true, plainDisplay: false))
        }
        func directory(battery: Bool) -> [SettingsSearchItem] {
            SettingsDirectory.searchItems(.enUS, language: .enUS, state: state(battery: battery))
        }
        let alerts = FeatureStrings.monitorAlerts(.enUS)
        for query in ["storage", "low storage", "free space", "warn"] {
            let groups = SettingsSearchSupport.groupedMatchingItems(
                query: query, items: directory(battery: true), isAvailable: { _ in true })
            let monitor = groups.first { $0.id == .monitor }
            suite.expect(monitor?.suggestions.contains {
                [alerts.disk, alerts.diskThreshold, alerts.section].contains($0.title)
            } == true, "searching \"\(query)\" offers the Monitor disk space alert")
        }
        suite.expect(SettingsSearchSupport.groupedMatchingItems(
            query: "storage", items: directory(battery: true), isAvailable: { $0 != .monitorDisk })
            .first { $0.id == .monitor }?.suggestions.contains { $0.title == alerts.disk } != true,
                     "the disk alert is not offered while disk monitoring is off")
        // The pages a search opens when it offers `label`. Another page can
        // show a row of the same name, such as the island's own shortcut.
        func pages(of label: String, query: String? = nil, battery: Bool = true,
                   without missing: Set<AppFeature> = []) -> Set<SettingsPage> {
            let isAvailable = { (feature: AppFeature) in !missing.contains(feature) }
            return Set(SettingsSearchSupport.groupedMatchingItems(
                query: query ?? label, items: directory(battery: battery), isAvailable: isAvailable)
                .flatMap(\.suggestions).filter { $0.title == label }
                .map { SettingsSearchSupport.route(for: $0, isAvailable: isAvailable).destination.page })
        }
        let agents = FeatureStrings.notchAgents(.enUS)
        let notch = FeatureStrings.notch(.enUS)
        let lowBattery = NotchLowBatteryStrings.localized(.enUS)
        // Each label is offered on its page with the `shownWithout` features
        // off, and hidden once `hiddenWithout` goes too or the Mac has no battery.
        let visibility: [(label: String, page: SettingsPage, shownWithout: Set<AppFeature>,
                          hiddenWithout: Set<AppFeature>?, needsBattery: Bool)] = [
            (Strings.enUS.uninstallerWatchTrashToggle, .uninstaller, [], [.uninstaller], false),
            (FeatureStrings.notchClipboardSize(.enUS).entrySize, .notch, [], [.clipboardHistory], false),
            (notch.clipboardActivity, .notch, [], [.clipboardHistory], false),
            (agents.budget, .notch, [], [.notchAgents], false),
            (FeatureStrings.notchActivities(.enUS).keepAwakeActivity, .notch, [.keepAwake], nil, false),
            (lowBattery.title, .notch, [], [.monitorPower], true),
            (lowBattery.early, .notch, [], [.monitorPower], true),
            (lowBattery.menuBar, .notch, [], [.monitorPower], true),
            (Strings.enUS.globalHotkeySection, .general, [], [.keepAwake], false),
            (Strings.enUS.batteryDisableBelow, .energy, [], [.keepAwake], true),
            (alerts.battery, .monitor, [], [.monitorPower], true),
            (alerts.batteryThreshold, .monitor, [], [.monitorPower], true),
            (alerts.batteryTemperature, .monitor, [], [.monitorPower], true),
            // The CPU alert shares this name.
            (alerts.batteryTemperatureThreshold, .monitor, [.monitorCPU], [.monitorPower], true),
        ]
        for row in visibility {
            suite.expect(pages(of: row.label, without: row.shownWithout).contains(row.page),
                         "search offers \"\(row.label)\" on \(row.page) while Settings shows it")
            if let hidden = row.hiddenWithout {
                suite.expect(!pages(of: row.label, without: row.shownWithout.union(hidden)).contains(row.page),
                             "search hides \"\(row.label)\" on \(row.page) without \(hidden.map(\.rawValue).sorted())")
            }
            if row.needsBattery {
                suite.expect(!pages(of: row.label, battery: false, without: row.shownWithout).contains(row.page),
                             "search hides \"\(row.label)\" on \(row.page) on a Mac without a battery")
            }
        }
        suite.expect(pages(of: Strings.enUS.keepAwakeMouseJiggle, query: "jiggle").contains(.energy),
                     "searching \"jiggle\" offers the Keep Awake pointer movement")
        suite.expect(pages(of: Strings.enUS.monitorIntervalLabel, query: "interval").contains(.monitor),
                     "searching \"interval\" offers the Monitor update interval")
        func verify(_ label: String, query: String? = nil, opens destination: FeatureSettingsDestination,
                    shown: Bool = true, without missing: Set<AppFeature> = [], language: AppLanguage = .enUS) {
            let strings = Strings.localized(language)
            let items = SettingsDirectory.searchItems(strings, language: language, state: state())
            let available = { (feature: AppFeature) in !missing.contains(feature) }
            let query = query ?? label
            let suggestions = SettingsSearchSupport.groupedMatchingItems(query: query, items: items, isAvailable: available)
                .flatMap(\.suggestions).filter { $0.title == label }
            let routes = suggestions.map { SettingsSearchSupport.route(for: $0, isAvailable: available).destination }
            suite.expect(routes.contains(destination) == shown, "Settings visibility and route for \(query) (shown: \(shown))")
            if shown, let location = destination.notchLocation {
                let router = SettingsRouter()
                router.request(destination)
                let island = IslandSettings(router: router)
                island.revealDestination()
                suite.expect(island.tab == location.tab, "the island reveals the requested tab")
                if case .module(let module) = location {
                    suite.expect(island.selectedModule == module, "the island reveals \(module) inside Content")
                }
            }
        }

        let monitor = FeatureSettingsDestination(.monitor)
        let colors = FeatureStrings.menuBarAppearance(.enUS)
        for bars in [false, true, false] {
            defaults.set(bars ? "bars" : "values", forKey: DefaultsKey.menuBarMetricAppearance)
            verify(colors.normalColor, opens: monitor, shown: bars)
            verify(Strings.enUS.monitorCombineTemperatures, opens: monitor, shown: !bars)
        }

        let monitorAlerts = FeatureSettingsDestination(.monitor, sectionAnchor: .monitorAlerts)
        verify(alerts.disk, query: "ssd", opens: monitorAlerts)
        verify(alerts.disk, query: "ssd", opens: monitorAlerts, shown: false, without: [.monitorDisk])
        verify(alerts.diskThreshold, opens: monitorAlerts)
        defaults.set(false, forKey: DefaultsKey.monitorAlertDisk)
        verify(alerts.diskThreshold, opens: monitorAlerts, shown: false)
        verify(alerts.disk, opens: monitorAlerts)

        let agentsDestination = FeatureSettingsDestination(notch: .module(.agents))
        verify(agents.readout, opens: agentsDestination)
        defaults.set(false, forKey: DefaultsKey.notchAgentsLiveActivity)
        verify(agents.readout, opens: agentsDestination, shown: false)
        verify(agents.budget, opens: agentsDestination, shown: false, without: [.notchAgents])
        verify(Strings.enUS.hotkeyToggle, opens: FeatureSettingsDestination(.general))
        verify(Strings.enUS.hotkeyToggle, opens: FeatureSettingsDestination(.general),
               shown: false, without: [.keepAwake])
        suite.expect(pages(of: Strings.enUS.hotkeyToggle) == [.general],
                     "the Keep Awake switch in General does not lead to Shortcuts")
    }

    static func run(_ suite: TestSuite) {
        search(suite)
        suite.expect(Defaults.registeredDefaults[DefaultsKey.fanControlResume] as? Bool == false,
               "resuming fan control after a restart or sleep is opt-in")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.startupDidNotFinish] == nil,
               "a start that did not finish is a note for this machine, not a setting")

        // A stored shortcut is text on disk and can arrive edited, so the
        // number is checked before it ever reaches an API that takes a
        // narrower type.
        suite.expect(GlobalShortcut(storageValue: "command:-1") == nil,
               "a negative key code never becomes a shortcut")
        suite.expect(GlobalShortcut(storageValue: "command:99999999") == nil,
               "a key code past the end of the range never becomes a shortcut")
        suite.expect(GlobalShortcut(storageValue: "command:\(Int64.min)") == nil,
               "the smallest possible number never becomes a shortcut")
        suite.expect(!GlobalShortcut(keyCode: -1, modifiers: [.command]).isValid
                && !GlobalShortcut(keyCode: 70000, modifiers: [.command]).isValid,
               "a shortcut built with a number out of range is not valid")
        suite.expect(GlobalShortcut(keyCode: -1, modifiers: [.command]).carbonKeyCode == 0,
               "a number out of range converts to nothing instead of trapping")
        suite.expect(GlobalShortcut(storageValue: "control+option+command:40") != nil,
               "an ordinary stored shortcut still reads back")
    }
}

extension SettingsFeatureTests {
    static func windowActivationChecks(_ suite: TestSuite) {
        var windowRetention = WindowActivationRetention()
        let firstWindowNeedsPromotion = windowRetention.retain()
        let secondWindowNeedsPromotion = windowRetention.retain()
        let firstCloseNeedsDemotion = windowRetention.release()
        let lastCloseNeedsDemotion = windowRetention.release()
        let extraCloseNeedsDemotion = windowRetention.release()
        suite.expect(firstWindowNeedsPromotion && !secondWindowNeedsPromotion
                && !firstCloseNeedsDemotion && lastCloseNeedsDemotion
                && !extraCloseNeedsDemotion && windowRetention.count == 0,
               "user-facing windows share one balanced app activation lifetime")
        let appDelegateSource = (try? String(
            contentsOfFile: "Sources/Brim/App/AppDelegate.swift",
            encoding: .utf8)) ?? ""
        suite.expect(appDelegateSource.contains("if !settingsKeepsAppRegular {")
                && appDelegateSource.contains("WindowActivationPolicy.retain()")
                && appDelegateSource.contains("WindowActivationPolicy.release()"),
               "Settings retains Command Tab presence only while its window is visible")
    }
}
