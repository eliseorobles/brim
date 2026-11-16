// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation
import SwiftUI

enum NotchActivityTests {
    static func run(_ suite: TestSuite) {
        menuCoverContracts(suite)
        lowBatteryContracts(suite)
        compactMarginContracts(suite)
        keepAwakeContracts(suite)
        stringContracts(suite)
    }

    /// Keep Awake as an activity: off until turned on, gated like the others,
    /// last in the automatic order, and read in whole minutes like a timer.
    private static func keepAwakeContracts(_ suite: TestSuite) {
        let domain = "brim.tests.notch-keep-awake"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { defaults.set(value, forKey: key) }
        for (key, value) in AppFeature.availabilityDefaults { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        defaults.set(true, forKey: AppFeature.keepAwake.availabilityKey)
        suite.expect(!NotchKeepAwakeSupport.showsActivity(in: defaults),
                     "Keep Awake stays out of the closed island until it is turned on")
        defaults.set(true, forKey: DefaultsKey.notchKeepAwakeActivity)
        suite.expect(NotchKeepAwakeSupport.showsActivity(in: defaults), "the activity follows its own switch")
        defaults.set(false, forKey: AppFeature.keepAwake.availabilityKey)
        suite.expect(!NotchKeepAwakeSupport.showsActivity(in: defaults),
                     "removing Keep Awake from the hub removes its activity")
        defaults.set(true, forKey: AppFeature.keepAwake.availabilityKey)
        defaults.set(false, forKey: DefaultsKey.notchEnabled)
        suite.expect(!NotchKeepAwakeSupport.showsActivity(in: defaults), "the island's master switch gates it too")

        suite.expect(NotchSupport.compactActivity(agents: true, keepAwake: true) == .agents
                     && NotchSupport.compactActivity(agents: false, keepAwake: true) == .keepAwake,
                     "a session that can run all day yields to a working agent")
        suite.expect(NotchCompactActivity.keepAwake.module == .controls
                     && NotchCompactActivity.keepAwake.symbol == NotchControlItem.keepAwake.symbol,
                     "the activity opens Controls, where the Keep Awake tile is, and shows the tile's mark")

        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let locale = Locale(identifier: "en_US")
        func text(_ seconds: TimeInterval) -> String {
            NotchKeepAwakeSupport.compactText(until: now.addingTimeInterval(seconds), now: now, locale: locale)
        }
        suite.expect(text(30 * 60) == "30m" && text(30 * 60 - 0.5) == "30m" && text(29 * 60 + 1) == "30m"
                     && text(29 * 60) == "29m",
                     "a new half-hour session reads 30m until a whole minute has passed")
        suite.expect(text(60 * 60) == "1h00" && text(61 * 60) == "1h01" && text(8 * 3600) == "8h00"
                     && text(26 * 3600 + 5 * 60) == "26h05",
                     "hours read as 1h05, never as a clock, and without a limit")
        suite.expect(text(59 * 60) == "59m" && text(1) == "1m" && text(0) == "1m" && text(-30) == "1m",
                     "the last minute, and an end the session has not reached yet, still read one minute")
        for seconds: TimeInterval in [1, 59.5, 60, 61, 1799.5, 3600, 3601, 28_800] {
            let end = now.addingTimeInterval(seconds)
            let start = NotchKeepAwakeSupport.tickStart(until: end, now: now)
            let next = start.addingTimeInterval(60)
            let minutes = NotchKeepAwakeSupport.minutesLeft(until: end, now: now)
            suite.expect(start <= now && next > now
                         && NotchKeepAwakeSupport.minutesLeft(until: end, now: next.addingTimeInterval(-0.001)) == minutes
                         && NotchKeepAwakeSupport.minutesLeft(until: end, now: next) == max(1, minutes - 1),
                         "the minute clock wakes when the reading changes, \(seconds) seconds before the end")
        }

        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        for barHeight: CGFloat in [22, 24, 32, 40] {
            for notched in [false, true] {
                let original = NotchGeometry(screen: screen, safeAreaTop: notched ? 32 : 0,
                                             cameraWidth: notched ? 180 : 0, menuBarHeight: barHeight,
                                             compactSideRoom: 200)
                for end in [nil, now.addingTimeInterval(45 * 60), now.addingTimeInterval(26 * 3600)] {
                    let wing = NotchKeepAwakeSupport.stripWing(until: end, now: now, locale: locale, in: original)
                    let compact = original.compactKeepAwakeGeometry(wing: wing)
                    suite.expect(!compact.compactActivityUsesFooter
                                 && compact.compactActivityWingWidth >= min(wing, NotchKeepAwakeSupport.stripWingRange.upperBound)
                                 && compact.compactActivityWingWidth >= 42,
                                 "the cup and the time left keep readable wings beside the camera")
                }
            }
        }
    }

    private static func lowBatteryContracts(_ suite: TestSuite) {
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchLowBatteryTint] as? Bool == false
               && Defaults.registeredDefaults[DefaultsKey.notchLowBatteryThreshold] as? Int == 10
               && Defaults.registeredDefaults[DefaultsKey.notchLowBatteryEarly] as? Bool == false
               && Defaults.registeredDefaults[DefaultsKey.notchLowBatteryEarlyThreshold] as? Int == 20
               && Defaults.registeredDefaults[DefaultsKey.notchLowBatteryMenuBar] as? Bool == true,
               "the low battery warning starts off at 10%, amber at 20%")
        func warning(_ percent: Int?, plugged: Bool = false, tint: Bool = true, threshold: Int = 10,
                     early: Bool = false, earlyThreshold: Int = 20) -> BatteryWarning {
            NotchSupport.batteryWarning(percent: percent, externalConnected: plugged, tint: tint, threshold: threshold,
                                        early: early, earlyThreshold: earlyThreshold)
        }
        suite.expect(warning(10) == .low && warning(3) == .low && warning(11) == .none,
                     "the charge turns red at or below the chosen level")
        suite.expect(warning(5, tint: false) == .none && warning(15, tint: false, early: true) == .none,
                     "the charge keeps its color while the setting is off")
        suite.expect(warning(5, plugged: true) == .none && warning(15, plugged: true, early: true) == .none,
                     "a Mac on power never shows a warning")
        suite.expect(warning(nil) == .none, "an unknown charge is never shown as low")
        suite.expect(warning(25, threshold: 25) == .low && warning(26, threshold: 25) == .none, "the red level can be adjusted")
        suite.expect(warning(1, threshold: 0) == .low && warning(2, threshold: 0) == .none
                     && warning(99, threshold: 150) == .low && warning(100, threshold: 150) == .none,
                     "a stored red level outside the offered range is clamped")
        suite.expect(warning(20, early: true) == .early && warning(11, early: true) == .early
                     && warning(10, early: true) == .low && warning(21, early: true) == .none,
                     "the amber warning comes first and gives way to red")
        suite.expect(warning(15) == .none, "the amber warning stays off until it is turned on")
        suite.expect(warning(40, early: true, earlyThreshold: 40) == .early && warning(41, early: true, earlyThreshold: 40) == .none
                     && warning(100, early: true, earlyThreshold: 150) == .early,
                     "the amber level can be adjusted and is clamped")
        suite.expect(NotchSupport.earlyBatteryThreshold(28, above: 26) == 28
                     && NotchSupport.earlyBatteryThreshold(20, above: 26) == 27
                     && NotchSupport.earlyBatteryThreshold(10, above: 5) == 10
                     && NotchSupport.earlyBatteryThreshold(5, above: 99) == 100
                     && NotchSupport.earlyBatteryThreshold(150, above: 10) == 100
                     && NotchSupport.earlyBatteryThreshold(99, above: 150) == 100,
                     "the amber level stays within its range and above the red level")
        let domain = "brim.tests.low-battery"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        suite.expect(NotchSupport.batteryWarning(percent: 5, externalConnected: false, in: defaults) == .none,
                     "missing preferences show no warning")
        defaults.set(true, forKey: DefaultsKey.notchLowBatteryTint)
        defaults.set(true, forKey: DefaultsKey.notchLowBatteryEarly)
        suite.expect(NotchSupport.batteryWarning(percent: 10, externalConnected: false, in: defaults) == .low
                     && NotchSupport.batteryWarning(percent: 20, externalConnected: false, in: defaults) == .early
                     && NotchSupport.menuBarBatteryWarning(percent: 10, externalConnected: false, in: defaults) == .low,
                     "stored preferences use the default levels and reach the menu bar")
        defaults.set(false, forKey: DefaultsKey.notchLowBatteryMenuBar)
        suite.expect(NotchSupport.menuBarBatteryWarning(percent: 10, externalConnected: false, in: defaults) == .none
                     && NotchSupport.batteryWarning(percent: 10, externalConnected: false, in: defaults) == .low,
                     "the menu bar can keep its usual color while the island warns")
    }

    private static func menuCoverContracts(_ suite: TestSuite) {
        let domain = "brim.tests.notch-menu-cover"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchCoversMenus] as? Bool == true,
               "compact activity stays visible by default")
        suite.expect(NotchSupport.coversMenus(in: defaults), "missing menu-cover preferences use the visible default")
        defaults.set(false, forKey: DefaultsKey.notchCoversMenus)
        suite.expect(!NotchSupport.coversMenus(in: defaults), "an explicit choice to leave menus uncovered is preserved")
    }

    private static func compactMarginContracts(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let gap = NotchLayout.compactEdgeGap
        /// Distance from a centred box, anchored at `inset`, to the silhouette.
        func clearance(_ geometry: NotchGeometry, inset: CGFloat, boxHeight: CGFloat, radius: CGFloat) -> CGFloat {
            let surface = geometry.compactActivitySize
            let shoulder = geometry.compactActivityShoulder
            let corner = min(NotchLayout.surfaceRadius(height: surface.height),
                             (surface.width - shoulder * 2) / 2)
            let centre = CGPoint(x: shoulder + corner, y: surface.height - corner)
            let x = inset + geometry.compactActivityHorizontalPadding + radius
            let y = surface.height - (geometry.compactActivityContentHeight - boxHeight) / 2 - radius
            if y <= centre.y { return x - radius - shoulder }
            if x >= centre.x { return surface.height - y - radius }
            return corner - hypot(x - centre.x, y - centre.y) - radius
        }
        for barHeight: CGFloat in [24, 32, 37, 40, 44, 64] {
            for room: CGFloat in [44, 52, 56, 72, 100, 200] {
                for notched in [true, false] {
                    let geometry = NotchGeometry(screen: screen, safeAreaTop: notched ? 32 : 0,
                                                 cameraWidth: notched ? 180 : 160, layout: .compact,
                                                 menuBarHeight: barHeight, compactSideRoom: room)
                    let wing = geometry.compactActivityWingWidth
                    suite.expect(wing == 0 || wing >= 44,
                           "a compact strip either retracts its wings or keeps them wide enough to fill")
                    // The cup, an agent's mark in its frame and the ink of a
                    // reading. A box too tall for the strip has no inset that
                    // can clear the curve, and keeps the flat margin.
                    for (box, radius) in [(20.0, 10.0), (18.0, 9.0), (16.0 * 0.72, 0.0)] {
                        let side = min(box, geometry.compactActivityContentHeight - gap * 2)
                        guard side > 0 else { continue }
                        let corner = min(radius, side / 2)
                        let inset = geometry.compactActivityEdgeInset(boxHeight: side, radius: corner)
                        suite.expect(clearance(geometry, inset: inset, boxHeight: side, radius: corner) >= gap - 0.01,
                               "compact strip content keeps its breathing room from the curved edge")
                    }
                }
            }
        }
    }

    private static func stringContracts(_ suite: TestSuite) {
        for language in AppLanguage.allCases {
            for child in Mirror(reflecting: FeatureStrings.notchActivities(language)).children {
                if let value = child.value as? String {
                    suite.expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("—"),
                           "activity copy is present and human-readable for \(language.rawValue) \(child.label ?? "")")
                }
            }
        }
    }
}
