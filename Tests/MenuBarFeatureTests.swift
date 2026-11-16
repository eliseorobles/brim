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

enum MenuBarFeatureTests {
    static func run(_ suite: TestSuite) {
        func expectEqual(_ actual: String, _ expected: String, _ label: String,
                         file: StaticString = #filePath, line: UInt = #line) {
            suite.expect(actual == expected, "\(label): got \(actual), expected \(expected)",
                         file: file, line: line)
        }
        let registeredDefaults = Defaults.registeredDefaults
        func sourceBody(of source: String, from opening: String, to closing: String) -> String {
            guard let start = source.range(of: opening),
                  let end = source.range(of: closing, range: start.upperBound..<source.endIndex)
            else { return "" }
            return String(source[start.upperBound..<end.lowerBound])
        }

        let batteryVisibilitySuite = "brim.tests.batteryVisibility.\(UUID().uuidString)"
        if let batteryVisibilityDefaults = UserDefaults(suiteName: batteryVisibilitySuite) {
            batteryVisibilityDefaults.removePersistentDomain(forName: batteryVisibilitySuite)
            batteryVisibilityDefaults.set(false, forKey: DefaultsKey.monitorSysTemps)
            Defaults.migrateBatteryTemperatureVisibility(in: batteryVisibilityDefaults)
            suite.expect(!batteryVisibilityDefaults.bool(forKey: DefaultsKey.monitorPwrTemperature),
                   "moving battery temperature preserves a hidden temperature section")
            batteryVisibilityDefaults.set(true, forKey: DefaultsKey.monitorSysTemps)
            Defaults.migrateBatteryTemperatureVisibility(in: batteryVisibilityDefaults)
            suite.expect(!batteryVisibilityDefaults.bool(forKey: DefaultsKey.monitorPwrTemperature),
                   "subsequent System visibility changes cannot overwrite the Power choice")
            batteryVisibilityDefaults.removePersistentDomain(forName: batteryVisibilitySuite)
            Defaults.migrateBatteryTemperatureVisibility(in: batteryVisibilityDefaults)
            suite.expect(batteryVisibilityDefaults.bool(forKey: DefaultsKey.monitorPwrTemperature),
                   "a fresh installation keeps battery temperature visible in Power")
            batteryVisibilityDefaults.set(false, forKey: DefaultsKey.monitorSysTemps)
            Defaults.migrateBatteryTemperatureVisibility(in: batteryVisibilityDefaults)
            suite.expect(batteryVisibilityDefaults.bool(forKey: DefaultsKey.monitorPwrTemperature),
                   "a restored Power preference wins over the previous temperature section")
            batteryVisibilityDefaults.removePersistentDomain(forName: batteryVisibilitySuite)
        } else {
            suite.expect(false, "battery visibility migration has isolated preferences")
        }
        suite.expect(registeredDefaults[DefaultsKey.clipboardHistoryShortcutEnabled] as? Bool == true,
               "clipboard history shortcut is ready when clipboard history is enabled")
        suite.expect(registeredDefaults[DefaultsKey.clipboardHistoryShortcut] as? String
               == GlobalShortcut.clipboardDefault.storageValue,
               "clipboard history shortcut defaults to Ctrl+Opt+Cmd+V")
        suite.expect(GlobalShortcut(keyCode: Int64(kVK_ANSI_V), modifiers: [.command])
                   .isStandardPasteCommand,
               "Cmd+V is recognized when plain-text paste must release its own hotkey")
        suite.expect(!GlobalShortcut.pastePlainDefault.isStandardPasteCommand,
               "the default plain-text paste shortcut does not intercept synthesized Cmd+V")
        suite.expect(!GlobalShortcut(keyCode: Int64(kVK_ANSI_C), modifiers: [.command])
                   .isStandardPasteCommand,
               "other Command shortcuts never release the plain-text paste hotkey")
        suite.expect(registeredDefaults[DefaultsKey.panelUtilityUninstaller] as? Bool == true,
               "panel uninstaller utility is visible by default")
        suite.expect(registeredDefaults[DefaultsKey.panelUtilityHomebrew] as? Bool == true,
               "panel Homebrew utility is visible by default")
        suite.expect(registeredDefaults[DefaultsKey.menuBarMetricSpacing] as? String == "compact",
               "menu bar metric spacing defaults to the compact look")
        suite.expect(registeredDefaults[DefaultsKey.menuBarMetricAppearance] as? String == "values",
               "menu bar usage metrics keep numeric values by default")
        suite.expect(registeredDefaults[DefaultsKey.menuBarUsageBarNormalColor] as? String == "#64D2FF",
               "menu bar bars use a bright normal color by default")
        suite.expect(registeredDefaults[DefaultsKey.menuBarUsageBarElevatedColor] as? String == "#FFD60A"
               && registeredDefaults[DefaultsKey.menuBarUsageBarCriticalColor] as? String == "#FF453A",
               "menu bar bars keep visible elevated and critical defaults")
        suite.expect(registeredDefaults[DefaultsKey.menuBarUsageBarMediumThreshold] as? Int == 70
               && registeredDefaults[DefaultsKey.menuBarUsageBarHighThreshold] as? Int == 90,
               "menu bar bar thresholds default to seventy and ninety percent")
        suite.expect(Defaults.sanitizedMonitorAlertCooldown(2) == 2,
               "the two minute alert cooldown is a valid stored choice")
        suite.expect(Defaults.sanitizedMonitorAlertCooldown(7) == 15,
               "unknown alert cooldowns fall back to fifteen minutes")
        suite.expect(registeredDefaults[DefaultsKey.monitorAlertBatteryTemperature] as? Bool == false,
               "battery temperature alerts are opt-in")
        suite.expect(registeredDefaults[DefaultsKey.monitorAlertBatteryTemperatureThreshold] as? Int == 40,
               "battery temperature alerts default to forty degrees")
        suite.expect(Defaults.sanitizedMenuBarMetricSpacing("standard") == "standard",
               "standard menu bar spacing is a valid stored choice")
        suite.expect(Defaults.sanitizedMenuBarMetricSpacing("banana") == "compact",
               "unknown menu bar spacing values fall back to the compact default")
        suite.expect(Defaults.sanitizedMenuBarMetricAppearance("bars") == "bars",
               "bar appearance is a valid stored choice")
        suite.expect(Defaults.sanitizedMenuBarMetricAppearance("banana") == "values",
               "unknown menu bar appearances fall back to numeric values")
        suite.expect(MenuBarMetricAppearance.values.allowsCombinedTemperatures,
               "numeric menu bar values may combine usage and temperature")
        suite.expect(!MenuBarMetricAppearance.bars.allowsCombinedTemperatures,
               "menu bar bars keep usage and temperature separate")
        suite.expectClose(MenuBarUsageBarSupport.memoryFraction(used: 3, total: 4) ?? -1, 0.75,
                    "menu bar memory bars use the current used fraction")
        suite.expect(MenuBarUsageBarSupport.memoryFraction(used: 3, total: 0) == nil,
               "menu bar memory bars keep missing totals unavailable")
        suite.expectClose(MenuBarUsageBarSupport.clampedFraction(-0.2), 0,
                    "menu bar bars clamp negative readings")
        suite.expectClose(MenuBarUsageBarSupport.clampedFraction(1.4), 1,
                    "menu bar bars clamp readings above full")
        suite.expect(MenuBarUsageBarSupport.fillLevel(for: 0.5, steps: 16) == 8,
               "menu bar bars quantize fractions to visible fill steps")
        suite.expect(MenuBarUsageBarSupport.level(for: 0.69) == .normal,
               "menu bar usage stays blue below seventy percent")
        suite.expect(MenuBarUsageBarSupport.level(for: 0.70) == .elevated,
               "menu bar usage turns yellow at seventy percent")
        suite.expect(MenuBarUsageBarSupport.level(for: 0.89) == .elevated,
               "menu bar usage stays yellow below ninety percent")
        suite.expect(MenuBarUsageBarSupport.level(for: 0.90) == .critical,
               "menu bar usage turns red at ninety percent")
        suite.expect(MenuBarUsageBarSupport.level(for: 0.50,
                                            mediumPercent: 40,
                                            highPercent: 80) == .elevated,
               "custom menu bar medium thresholds change the bar level")
        suite.expect(MenuBarUsageBarSupport.level(for: 0.80,
                                            mediumPercent: 40,
                                            highPercent: 80) == .critical,
               "custom menu bar high thresholds change the bar level")
        let repairedBarThresholds = MenuBarUsageBarSupport.thresholds(medium: 100, high: 20)
        suite.expect(repairedBarThresholds.medium == 99 && repairedBarThresholds.high == 100,
               "invalid menu bar thresholds keep medium below high")
        suite.expect(MenuBarUsageBarSupport.sanitizedColorHex(" 64d2ff ", fallback: "#000000") == "#64D2FF",
               "menu bar colors normalize stored hex values")
        suite.expect(MenuBarUsageBarSupport.sanitizedColorHex("bad", fallback: "#FFD60A") == "#FFD60A",
               "invalid menu bar colors use their visible fallback")
        let customBarRGB = MenuBarUsageBarSupport.rgb(for: "#804020", fallback: "#000000")
        suite.expectClose(customBarRGB.red, 128.0 / 255.0, "menu bar color parses red")
        suite.expectClose(customBarRGB.green, 64.0 / 255.0, "menu bar color parses green")
        suite.expectClose(customBarRGB.blue, 32.0 / 255.0, "menu bar color parses blue")
        suite.expect(MenuBarUsageBarSupport.hex(red: 1, green: 0.5, blue: 0) == "#FF8000",
               "menu bar color picker writes stable hex values")
        suite.expect(MenuBarSpacingSupport.digitMatchedReserve(for: "14%") == "88%",
               "compact spacing reserves the current digit count for percentages")
        suite.expect(MenuBarSpacingSupport.digitMatchedReserve(for: "999°") == "888°",
               "compact spacing reserves the current digit count for temperatures")
        suite.expect(MenuBarSpacingSupport.digitMatchedReserve(for: "1.5M") == "8.8M",
               "compact spacing keeps units and separators while widening digits")
        suite.expect(MenuBarSpacingSupport.digitMatchedReserve(for: "") == "",
               "compact spacing reserve of an empty value stays empty")
        suite.expect(MenuBarSpacingSupport.digitMatchedReserve(for: "4%", minimumDigits: 2) == "88%",
               "compact spacing pads single digits up to the stability floor")
        suite.expect(MenuBarSpacingSupport.digitMatchedReserve(for: "14%", minimumDigits: 2) == "88%",
               "a one and a two digit value reserve the same width, so 4% to 10% never moves the bar")
        suite.expect(MenuBarSpacingSupport.digitMatchedReserve(for: "100%", minimumDigits: 2) == "888%",
               "values above the floor keep their own digit count")
        suite.expect(MenuBarSpacingSupport.compactFloor(currentDigits: 1, highWater: nil) == 2,
               "the compact floor starts at two digits")
        suite.expect(MenuBarSpacingSupport.compactFloor(currentDigits: 3, highWater: 2) == 3,
               "a three digit value raises the floor")
        suite.expect(MenuBarSpacingSupport.compactFloor(currentDigits: 2, highWater: 3) == 3,
               "the session high-water mark keeps a block from shrinking back and wobbling")
        suite.expect(MenuBarSpacingSupport.blockGlue(readableStyle: false, spacing: .standard) == " ",
               "standard dense spacing keeps the full space between blocks")
        suite.expect(MenuBarSpacingSupport.blockGlue(readableStyle: false, spacing: .compact) == "\u{200A}",
               "compact dense spacing joins blocks with a hair space")
        suite.expect(MenuBarSpacingSupport.blockGlue(readableStyle: true, spacing: .compact) == " ",
               "compact readable spacing tightens the double space to a single one")
        suite.expect(StatusItemAnchorSupport.anchorDriftX(clickX: 1135, reportedMidX: 1452, buttonWidth: 38) == -317,
               "a click far left of the status item's reported frame re-anchors the panel at the click")
        suite.expect(StatusItemAnchorSupport.anchorDriftX(clickX: 1452, reportedMidX: 1135, buttonWidth: 38) == 317,
               "a click far right of the status item's reported frame re-anchors the panel at the click")
        suite.expect(StatusItemAnchorSupport.anchorDriftX(clickX: 1150, reportedMidX: 1144, buttonWidth: 38) == nil,
               "a click inside the status button never counts as drift")
        suite.expect(StatusItemAnchorSupport.anchorDriftX(clickX: 1186, reportedMidX: 1144, buttonWidth: 38) == nil,
               "a sloppy click just past the button edge stays within the drift slack")
        suite.expect(StatusItemAnchorSupport.anchorDriftX(clickX: 1188, reportedMidX: 1144, buttonWidth: 38) == 44,
               "a click beyond the slack re-anchors by the full offset")
        suite.expect(StatusItemAnchorSupport.anchorDriftX(clickX: 1240, reportedMidX: 1144, buttonWidth: 197) == nil,
               "clicks near the edge of a wide metrics item stay anchored to the item")

        suite.expect(StatusItemAnchorSupport.shouldReturnActivation(to: 501, ownPID: 900, frontmostPID: 900,
                                                                    ownWindowIsKey: false, closeReason: .escape),
               "closing the panel hands activation back to the app that was in front before it")
        suite.expect(!StatusItemAnchorSupport.shouldReturnActivation(to: 501, ownPID: 900, frontmostPID: 777,
                                                                     ownWindowIsKey: false, closeReason: .escape),
               "an app the person switched to while the panel was open keeps activation")
        suite.expect(!StatusItemAnchorSupport.shouldReturnActivation(to: 501, ownPID: 900, frontmostPID: 900,
                                                                     ownWindowIsKey: true, closeReason: .escape),
               "a Brim window that took focus from the panel keeps Brim active")
        suite.expect(!StatusItemAnchorSupport.shouldReturnActivation(to: nil, ownPID: 900, frontmostPID: 900,
                                                                     ownWindowIsKey: false, closeReason: .escape),
               "a panel opened while Brim was already in front has nothing to hand back")
        suite.expect(!StatusItemAnchorSupport.shouldReturnActivation(to: 900, ownPID: 900, frontmostPID: 900,
                                                                     ownWindowIsKey: false, closeReason: .escape),
               "Brim never hands activation back to itself")
        suite.expect(!StatusItemAnchorSupport.shouldReturnActivation(to: 501, ownPID: 900, frontmostPID: nil,
                                                                     ownWindowIsKey: false, closeReason: .escape),
               "no known frontmost app means nothing is taken from anyone")
        for (reason, returns) in [(PanelCloseReason.escape, true), (.statusItem, true),
                                  (.outsideClick, false), (.action, false)] {
            suite.expect(StatusItemAnchorSupport.shouldReturnActivation(to: 501, ownPID: 900, frontmostPID: 900,
                                                                        ownWindowIsKey: false,
                                                                        closeReason: reason) == returns,
                   returns ? "a \(reason) dismissal with nothing taking over hands activation back"
                           : "a \(reason) close leaves activation to whatever takes over")
        }
        suite.expect(!StatusItemAnchorSupport.shouldReturnActivation(to: 501, ownPID: 900, frontmostPID: 900,
                                                                     ownWindowIsKey: false, closeReason: nil),
               "a close Brim did not ask for leaves activation alone")

        let showing: Set<UInt64> = [3, 7]
        suite.expect(StatusItemAnchorSupport.handbackWouldSwitchDesktop(windowSpaces: [[1], [2]],
                                                                        visibleSpaces: showing),
               "an app whose windows are all on a desktop that is not showing is not handed activation")
        suite.expect(!StatusItemAnchorSupport.handbackWouldSwitchDesktop(windowSpaces: [[1], [2, 7]],
                                                                         visibleSpaces: showing),
               "an app with a window on a desktop that is showing gets activation back")
        suite.expect(!StatusItemAnchorSupport.handbackWouldSwitchDesktop(windowSpaces: [],
                                                                         visibleSpaces: showing),
               "an app with no windows open gets activation back")
        suite.expect(!StatusItemAnchorSupport.handbackWouldSwitchDesktop(windowSpaces: [[]],
                                                                         visibleSpaces: showing),
               "a leftover surface on no desktop does not count as a window")
        suite.expect(StatusItemAnchorSupport.handbackWouldSwitchDesktop(windowSpaces: [[], [1]],
                                                                        visibleSpaces: showing),
               "a leftover surface does not keep a window on a hidden desktop from counting")
        suite.expect(!StatusItemAnchorSupport.handbackWouldSwitchDesktop(windowSpaces: [[1]],
                                                                         visibleSpaces: nil),
               "unknown desktops keep handing activation back")

        let ownApp: (Int) -> Bool = { $0 == 900 }
        suite.expect(StatusItemAnchorSupport.panelActivationSource(after: .appActivated(777), current: 501,
                                                                   isOwnApp: ownApp) == 777,
               "another app becoming active while the panel is open replaces the remembered app")
        suite.expect(StatusItemAnchorSupport.panelActivationSource(after: .appActivated(900), current: 501,
                                                                   isOwnApp: ownApp) == 501,
               "Brim taking activation back from the panel keeps the remembered app")
        suite.expect(StatusItemAnchorSupport.panelActivationSource(after: .appActivated(777), current: nil,
                                                                   isOwnApp: ownApp) == 777,
               "an app activated after the remembered one was dropped becomes the one to return to")
        suite.expect(StatusItemAnchorSupport.panelActivationSource(after: PanelActivationChange<Int>.activeSpaceChanged,
                                                                   current: 501, isOwnApp: ownApp) == nil,
               "a desktop switch while the panel is open drops the remembered app")

        MenuPanelRecoveryTests.run { suite.expect($0, $1) }
        MenuPanelKeyTests.run(suite)

        // The built-in display and a taller one placed to its left.
        let builtInScreen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let secondScreen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let attachedScreens = [builtInScreen, secondScreen]
        suite.expect(!StatusItemAnchorSupport.isTrustworthyStatusFrame(CGRect(x: 1135, y: 932, width: 0, height: 0),
                                                                 screenFrames: attachedScreens),
               "a status item frame with no size is never an anchor")
        suite.expect(!StatusItemAnchorSupport.isTrustworthyStatusFrame(CGRect(x: 1135, y: 950, width: 38, height: 37),
                                                                 screenFrames: attachedScreens),
               "a status item parked above the top edge is not an anchor")
        suite.expect(StatusItemAnchorSupport.isTrustworthyStatusFrame(CGRect(x: 1135, y: 919, width: 38, height: 37),
                                                                screenFrames: attachedScreens),
               "a status item sitting in the menu bar band is a trustworthy anchor")
        suite.expect(StatusItemAnchorSupport.isTrustworthyStatusFrame(CGRect(x: -1000, y: 1143, width: 38, height: 37),
                                                                screenFrames: attachedScreens),
               "the menu bar band follows each screen's own top edge")
        suite.expect(!StatusItemAnchorSupport.isTrustworthyStatusFrame(CGRect(x: 1135, y: 0, width: 38, height: 37),
                                                                 screenFrames: attachedScreens),
               "a frame down at the bottom of a screen is not a menu bar item")

        // A screen showing a fullscreen window reserves no menu bar: its
        // visible area is the whole frame. The band is a fixed thickness off
        // the screen's own top edge, so an item revealed on hover still counts;
        // a band measured as `frame.maxY - visibleFrame.maxY` would collapse to
        // nothing here and decline the icon while it is visible and clickable.
        let fullscreenScreen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let fullscreenVisibleFrame = fullscreenScreen
        suite.expect(StatusItemAnchorSupport.menuBarBand > fullscreenScreen.maxY - fullscreenVisibleFrame.maxY,
               "the menu bar band does not shrink to what a fullscreen screen reserves")
        suite.expect(StatusItemAnchorSupport.isTrustworthyStatusFrame(CGRect(x: 1135, y: 919, width: 38, height: 37),
                                                                screenFrames: [fullscreenScreen]),
               "a status item revealed over a fullscreen window is a trustworthy anchor")

        // These AppKit owners are not part of the pure-helper test binary, so
        // pin that the status item cannot consume a parked status-item frame.
        let statusAnchorAppDelegateSource = (try? String(
            contentsOfFile: "Sources/Brim/App/AppDelegate.swift",
            encoding: .utf8)) ?? ""
        let stripCommentLines: (String) -> String = {
            $0.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        // Sliced at the closing brace of the function itself, so the slice can
        // never run past it into an unrelated body that happens to carry the
        // same words.
        let statusControllerSource = (try? String(
            contentsOfFile: "Sources/Brim/App/StatusItemController.swift",
            encoding: .utf8)) ?? ""
        let statusHitTestCode = stripCommentLines((statusControllerSource
            .components(separatedBy: "func containsStatusItem(at screenPoint: NSPoint) -> Bool {").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        let statusFrameCall = "StatusItemAnchorSupport.isTrustworthyStatusFrame("
        suite.expect(statusHitTestCode.contains(statusFrameCall) && statusHitTestCode.contains("return false"),
               "status-item hit testing rejects an untrustworthy frame")
        suite.expect(statusHitTestCode.contains("clipboardPreviewStatusItem"),
               "status-item hit testing also covers the clipboard preview item")

        // MARK: The panel surface reaches the popover arrow (issue #1030)

        // AppKit hands the hosted panel a safe area for the popover's border and
        // draws the arrow on the frame itself, so a surface that stopped at the
        // panel would leave the tip in the plain system material. None of these
        // owners compiles into this binary, so pin the three pieces that together
        // carry the panel's own surface out to the tip.
        let popoverSetUpCode = stripCommentLines((statusAnchorAppDelegateSource
            .components(separatedBy: "private func setUpPopover() {").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        suite.expect(popoverSetUpCode.contains("popover.hasFullSizeContent = PanelSurface.popoverHostsFullSizeContent"),
               "the panel is hosted across the whole popover, arrow band included, where AppKit supports it")
        let panelThemeSource = (try? String(
            contentsOfFile: "Sources/Brim/UI/Theme.swift",
            encoding: .utf8)) ?? ""
        // macOS 15 publishes the full-size safe area but leaves the view at its
        // content size in the frame's corner, so the popover grows and shows a
        // band of system material along its top and right edges.
        let fullSizeGateCode = stripCommentLines((panelThemeSource
            .components(separatedBy: "static var popoverHostsFullSizeContent: Bool {").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        suite.expect(fullSizeGateCode.contains("if #available(macOS 26.0, *) { return true }")
                   && fullSizeGateCode.contains("return false"),
               "full-size popover content is limited to macOS 26, where AppKit fills the balloon with it")
        let panelGlassCode = stripCommentLines((panelThemeSource
            .components(separatedBy: "private struct PanelGlassSurface: View {").last ?? "")
            .components(separatedBy: "\n}").first ?? "")
        suite.expect(panelGlassCode.contains("} else if PanelSurface.popoverHostsFullSizeContent {\n            surface.ignoresSafeArea()\n        } else {\n            Color.clear"),
               "a full-size panel fills the arrow; an inset panel leaves the native popover material visible")
        suite.expect(!panelGlassCode.isEmpty
                   && !panelGlassCode.contains("RoundedRectangle")
                   && !panelGlassCode.contains("cornerRadius")
                   && !panelGlassCode.contains("strokeBorder"),
               "the panel leaves the corners and rim to the popover, without a second rounded outline (#2225)")
        suite.expect(panelGlassCode.contains(".glassEffect(.regular, in: Rectangle())")
                   && panelGlassCode.contains("Rectangle()\n            .fill(.regularMaterial)"),
               "both the standard and the Liquid Glass surface fill the whole balloon, no shape of their own")
        let panelViewSource = (try? String(
            contentsOfFile: "Sources/Brim/UI/MenuPanel/MenuPanelView.swift",
            encoding: .utf8)) ?? ""
        let panelBodyCode: (String) -> String = { header in
            stripCommentLines((panelViewSource.components(separatedBy: header).last ?? "")
                .components(separatedBy: "\n    }").first ?? "")
        }
        suite.expect(panelBodyCode("private var navigablePanel: some View {").contains(".panelGlassSurface()")
                   && panelBodyCode("private var metricPanel: some View {").contains(".panelGlassSurface()"),
               "both the navigable panel and the metric panel wear that surface")

        // The popover window is the panel plus 13 pt for the arrow and 13 pt
        // below it. A window taller than the usable height opens beside the
        // icon (issue #2225), so the height cap has to leave at least 26 pt.
        let panelCapMargin = panelBodyCode("private var maxHeight: CGFloat {")
            .components(separatedBy: "?? 760) - ").dropFirst().first
            .flatMap { Int($0.prefix(while: \.isNumber)) } ?? 0
        suite.expect(panelCapMargin >= 26,
               "a panel at its height cap still fits under its icon, arrow and bottom margin included")

        // The panel keeps its top edge and its center while its content resizes.
        let panelArea = CGRect(x: 0, y: 0, width: 1470, height: 932)
        let shortPanel = StatusItemAnchorSupport.pinnedPanelFrame(size: CGSize(width: 332, height: 375),
                                                                  anchorMidX: 1283, anchorTop: 932,
                                                                  visibleFrame: panelArea)
        let tallPanel = StatusItemAnchorSupport.pinnedPanelFrame(size: CGSize(width: 332, height: 633),
                                                                 anchorMidX: 1283, anchorTop: 932,
                                                                 visibleFrame: panelArea)
        let shrunkPanel = StatusItemAnchorSupport.pinnedPanelFrame(size: CGSize(width: 332, height: 375),
                                                                   anchorMidX: 1283, anchorTop: 932,
                                                                   visibleFrame: panelArea)
        suite.expect(shortPanel.midX == 1283 && tallPanel.midX == 1283 && shrunkPanel.midX == 1283,
               "the pinned panel stays centered on its anchor through a content resize")
        suite.expect(shortPanel.maxY == 932 && tallPanel.maxY == 932 && shrunkPanel.maxY == 932,
               "a taller panel grows downward instead of moving its top edge")
        suite.expect(shortPanel == shrunkPanel,
               "going back to the first tab lands the panel exactly where it started")
        suite.expect(StatusItemAnchorSupport.pinnedPanelFrame(size: CGSize(width: 332, height: 375),
                                                        anchorMidX: 20, anchorTop: 932,
                                                        visibleFrame: panelArea).minX == 8,
               "a panel anchored past the left edge stops at the margin")
        suite.expect(StatusItemAnchorSupport.pinnedPanelFrame(size: CGSize(width: 332, height: 375),
                                                        anchorMidX: 1465, anchorTop: 932,
                                                        visibleFrame: panelArea).maxX == 1462,
               "a panel anchored past the right edge stops at the margin")
        suite.expect(StatusItemAnchorSupport.pinnedPanelFrame(size: CGSize(width: 332, height: 375),
                                                        anchorMidX: -1910, anchorTop: 1155,
                                                        visibleFrame: CGRect(x: -1920, y: 100,
                                                                             width: 1920, height: 1055))
                == CGRect(x: -1912, y: 780, width: 332, height: 375),
               "a display left of the built-in one clamps against its own negative origin")
        suite.expect(StatusItemAnchorSupport.pinnedPanelFrame(size: CGSize(width: 332, height: 633),
                                                        anchorMidX: 700, anchorTop: 300,
                                                        visibleFrame: CGRect(x: 0, y: 0,
                                                                             width: 1470, height: 300)).maxY == 300,
               "a screen too short for the panel still shows its top")
        suite.expect(registeredDefaults[DefaultsKey.menuBarHideIconWithMetrics] as? Bool == false,
               "the menu bar icon stays visible by default")
        suite.expect(MenuBarSpacingSupport.keepAwakeSignals(active: true, tint: .orange, style: .brim)
                     && MenuBarSpacingSupport.keepAwakeSignals(active: true, tint: .none, style: .coffee),
               "an active Keep Awake brings back the glyph that shows it")
        suite.expect(!MenuBarSpacingSupport.keepAwakeSignals(active: false, tint: .orange, style: .coffee)
                     && !MenuBarSpacingSupport.keepAwakeSignals(active: true, tint: .none, style: .brim),
               "nothing returns while Keep Awake is off, or when its active glyph looks the same as the idle one")
        // Both hide decisions and the title's leading space ask it, and an open
        // panel holds it: the returning glyph widens the item, and a separate
        // main item coming back shifts the metric item the panel hangs from.
        let keepAwakeHoldCode = stripCommentLines((statusControllerSource
            .components(separatedBy: "func setPanelSignalsHeld(_ held: Bool) {").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        suite.expect(statusControllerSource
                        .components(separatedBy: "mustShowForSignal: keepAwakeSignal").count == 4,
               "every hide path brings the glyph back for a running Keep Awake")
        suite.expect(keepAwakeHoldCode.contains("heldKeepAwakeSignal = currentKeepAwakeSignal")
                     && keepAwakeHoldCode.contains("heldKeepAwakeSignal = nil")
                     && keepAwakeHoldCode.contains("refresh()")
                     && statusControllerSource.contains("heldKeepAwakeSignal ?? currentKeepAwakeSignal"),
               "starting or stopping Keep Awake from an open panel does not bring the glyph back under it")
        // popoverDidClose keeps the hold while the panel switches anchors, so
        // a switch that ends with the panel closed has to release it itself.
        // Otherwise the glyph ignores Keep Awake until the next panel closes.
        // Each failure branch is sliced at its own closing brace.
        for (header, guardEnd, branchEnd, condition, label) in [
            ("private func reanchorMetricPopover(", "activeMetric == detailKind else {",
             "\n            }", "if !self.popover.isShown {", "closes while moving between metric items"),
            ("private func useStablePopoverPositioningViewIfNeeded(", "view.window else {",
             "\n        }", "if !popover.isShown {", "does not come back on its stable anchor"),
        ] {
            let switchCode = stripCommentLines((statusAnchorAppDelegateSource
                .components(separatedBy: header).last ?? "")
                .components(separatedBy: "\n    }").first ?? "")
            let releaseCode = ((switchCode.components(separatedBy: guardEnd).dropFirst().first ?? "")
                .components(separatedBy: branchEnd).first ?? "")
                .components(separatedBy: condition).dropFirst().first ?? ""
            suite.expect(releaseCode.contains("statusController.setPanelSignalsHeld(false)")
                         && releaseCode.contains("releasePanelResources()")
                         && releaseCode.contains("endPanelActivationTracking()"),
                   "a panel that \(label) releases the held glyph, its resources and activation tracking")
        }
        suite.expect(MenuBarSpacingSupport.shouldHideStatusIcon(optionEnabled: true, separateMetrics: false,
                                                          metricsEnabled: true, renderedTitleLength: 12,
                                                          mustShowForSignal: false),
               "the glyph hides when metrics render in the title and the option is on")
        suite.expect(!MenuBarSpacingSupport.shouldHideStatusIcon(optionEnabled: false, separateMetrics: false,
                                                           metricsEnabled: true, renderedTitleLength: 12,
                                                           mustShowForSignal: false),
               "the glyph never hides while the option is off")
        suite.expect(!MenuBarSpacingSupport.shouldHideStatusIcon(optionEnabled: true, separateMetrics: false,
                                                           metricsEnabled: true, renderedTitleLength: 0,
                                                           mustShowForSignal: false),
               "an empty rendered title keeps the glyph, so the item can never turn invisible")
        suite.expect(!MenuBarSpacingSupport.shouldHideStatusIcon(optionEnabled: true, separateMetrics: false,
                                                           metricsEnabled: false, renderedTitleLength: 6,
                                                           mustShowForSignal: false),
               "a countdown-only title keeps the glyph when no metric is enabled")
        suite.expect(!MenuBarSpacingSupport.shouldHideStatusIcon(optionEnabled: true, separateMetrics: true,
                                                           metricsEnabled: true, renderedTitleLength: 6,
                                                           mustShowForSignal: false),
               "separate metric items keep the glyph in the otherwise empty main item")
        suite.expect(!MenuBarSpacingSupport.shouldHideStatusIcon(optionEnabled: true, separateMetrics: false,
                                                           metricsEnabled: true, renderedTitleLength: 12,
                                                           mustShowForSignal: true),
               "an available update or muted mic brings the glyph back to carry the signal")
        suite.expect(MenuBarSpacingSupport.shouldHideMainStatusItem(optionEnabled: true, separateMetrics: true,
                                                              metricItemsShown: 2, renderedTitleLength: 0,
                                                              mustShowForSignal: false),
               "with separate metric items installed the whole main item may step aside")
        suite.expect(!MenuBarSpacingSupport.shouldHideMainStatusItem(optionEnabled: true, separateMetrics: true,
                                                               metricItemsShown: 0, renderedTitleLength: 0,
                                                               mustShowForSignal: false),
               "no installed metric items keep the main item, so the app never vanishes")
        suite.expect(!MenuBarSpacingSupport.shouldHideMainStatusItem(optionEnabled: true, separateMetrics: true,
                                                               metricItemsShown: 2, renderedTitleLength: 5,
                                                               mustShowForSignal: false),
               "an active countdown renders in the main item and keeps it visible")
        suite.expect(!MenuBarSpacingSupport.shouldHideMainStatusItem(optionEnabled: true, separateMetrics: false,
                                                               metricItemsShown: 2, renderedTitleLength: 0,
                                                               mustShowForSignal: false),
               "the whole-item hiding only applies to the separate-items mode")

        // Dynamic Island may take the icon's place, but only while it runs:
        // with the island off or removed, nothing else on screen would lead
        // back to the app.
        suite.expect(registeredDefaults[DefaultsKey.notchHidesMenuBarIcon] as? Bool == false,
               "Dynamic Island only takes the icon's place when asked")
        let islandIconSuite = "brim.tests.islandMenuBarIcon"
        if let islandDefaults = UserDefaults(suiteName: islandIconSuite) {
            islandDefaults.removePersistentDomain(forName: islandIconSuite)
            defer { islandDefaults.removePersistentDomain(forName: islandIconSuite) }
            islandDefaults.set(true, forKey: AppFeature.notch.availabilityKey)
            islandDefaults.set(true, forKey: DefaultsKey.notchEnabled)
            suite.expect(!MenuBarSpacingSupport.islandHidesStatusIcon(in: islandDefaults),
                   "a running island leaves the icon alone until asked")
            islandDefaults.set(true, forKey: DefaultsKey.notchHidesMenuBarIcon)
            suite.expect(MenuBarSpacingSupport.islandHidesStatusIcon(in: islandDefaults),
                   "a running island takes the icon's place when asked")
            islandDefaults.set(true, forKey: DefaultsKey.notchHideInFullscreen)
            suite.expect(!MenuBarSpacingSupport.islandHidesStatusIcon(
                in: islandDefaults, hiddenInFullscreen: true),
                   "the menu bar icon returns while the island is hidden in fullscreen")
            suite.expect(MenuBarSpacingSupport.islandHidesStatusIcon(
                in: islandDefaults, hiddenInFullscreen: false),
                   "the saved icon preference resumes when the island leaves fullscreen")
            islandDefaults.set(false, forKey: DefaultsKey.notchEnabled)
            suite.expect(!MenuBarSpacingSupport.islandHidesStatusIcon(in: islandDefaults),
                   "switching the island off brings the icon back")
            islandDefaults.set(true, forKey: DefaultsKey.notchEnabled)
            islandDefaults.set(false, forKey: AppFeature.notch.availabilityKey)
            suite.expect(!MenuBarSpacingSupport.islandHidesStatusIcon(in: islandDefaults),
                   "removing the island in the hub brings the icon back")
        }

        // A pinned metric that momentarily has nothing to show keeps its item
        // instead of being taken away and put back every tick.
        suite.expect(MenuBarSpacingSupport.keepsMetricStatusItem(hasRenderedTitle: true, itemExists: false),
               "a metric with something to show gets its own item")
        suite.expect(MenuBarSpacingSupport.keepsMetricStatusItem(hasRenderedTitle: false, itemExists: true,
                                                           consecutiveEmptyRenders: 1),
               "a reading that goes missing for a tick blanks its item instead of removing it")
        suite.expect(!MenuBarSpacingSupport.keepsMetricStatusItem(
            hasRenderedTitle: false, itemExists: true,
            consecutiveEmptyRenders: MenuBarSpacingSupport.emptyMetricRendersBeforeRemoval),
               "a reading that stops for good takes its item away instead of leaving a gap")
        suite.expect(MenuBarSpacingSupport.keepsMetricStatusItem(
            hasRenderedTitle: true, itemExists: true,
            consecutiveEmptyRenders: 99),
               "a reading that comes back keeps its item whatever came before")
        suite.expect(!MenuBarSpacingSupport.keepsMetricStatusItem(hasRenderedTitle: false, itemExists: false),
               "a metric with nothing to show yet gets no item at all")
        suite.expect(MenuBarSpacingSupport.keepsMetricStatusItem(hasRenderedTitle: true, itemExists: true),
               "an item already showing a reading stays")
        suite.expect(!MenuBarSpacingSupport.shouldHideMainStatusItem(optionEnabled: true, separateMetrics: true,
                                                               metricItemsShown: 2, renderedTitleLength: 0,
                                                               mustShowForSignal: true),
               "a signal brings the main item back even in the separate-items mode")
        suite.expect(MenuBarSpacingSupport.needsTitleRefreshTimer(keepAwakeActive: true,
                                                            showsCountdown: true,
                                                            hasEndDate: true),
               "a visible finite Keep Awake countdown owns the title timer")
        suite.expect(!MenuBarSpacingSupport.needsTitleRefreshTimer(keepAwakeActive: false,
                                                             showsCountdown: true,
                                                             hasEndDate: true)
                && !MenuBarSpacingSupport.needsTitleRefreshTimer(keepAwakeActive: true,
                                                                  showsCountdown: false,
                                                                  hasEndDate: true)
                && !MenuBarSpacingSupport.needsTitleRefreshTimer(keepAwakeActive: true,
                                                                  showsCountdown: true,
                                                                  hasEndDate: false),
               "idle, hidden and indefinite Keep Awake titles need no timer")
        let statusPlacementSuite = "brim.tests.statusItemPlacement"
        if let statusDefaults = UserDefaults(suiteName: statusPlacementSuite) {
            statusDefaults.removePersistentDomain(forName: statusPlacementSuite)
            suite.expect(StatusItemPlacementSupport.placementGeneration(in: statusDefaults) == 0,
                   "initial placement generation is 0")
            suite.expect(StatusItemPlacementSupport.mainAutosaveName(in: statusDefaults) == "BrimMenuBarItem",
                   "generation 0 uses base autosave name")

            // The coordinate macOS saves for the icon is what puts it back in
            // the same spot on the next launch. 3.3.3 deleted the one written
            // by the older recovery on every launch, which moved the icon to
            // where a first-time item goes and, on a full bar, out of sight.
            let legacyKey = "NSStatusItem Preferred Position BrimMenuBarItem"
            statusDefaults.set(64.0, forKey: legacyKey)
            StatusItemPlacementSupport.clearRememberedVisibility(in: statusDefaults)
            suite.expect(statusDefaults.double(forKey: legacyKey) == 64.0,
                   "an icon placed by the older recovery keeps its spot through an update")

            statusDefaults.set(320.5, forKey: legacyKey)
            StatusItemPlacementSupport.clearRememberedVisibility(in: statusDefaults)
            suite.expect(statusDefaults.double(forKey: legacyKey) == 320.5,
                   "an icon the person arranged themselves keeps its spot too")

            StatusItemPlacementSupport.bumpPlacementGeneration(in: statusDefaults)
            let gen1Name = StatusItemPlacementSupport.mainAutosaveName(in: statusDefaults)
            suite.expect(gen1Name == "BrimMenuBarItem.1",
                   "bumped generation produces numbered autosave name")
            suite.expect(statusDefaults.object(forKey: "NSStatusItem Preferred Position BrimMenuBarItem.1") == nil,
                   "a reset lets macOS place the full item without a machine-specific position")
            suite.expect(statusDefaults.object(forKey: "NSStatusItem Preferred Position BrimMenuBarItem") == nil,
                   "bumping drops the previous identity's preferred position")

            // Recovery keeps the spot the person arranged and only drops the
            // hidden state macOS remembered: an item that starts over with no
            // saved position is born against the notch, the first place a
            // crowded bar hides.
            let gen1Position = "NSStatusItem Preferred Position BrimMenuBarItem.1"
            statusDefaults.set(280.0, forKey: gen1Position)
            statusDefaults.set(false, forKey: "NSStatusItem Visible BrimMenuBarItem.1")
            statusDefaults.set(false, forKey: "NSStatusItem VisibleCC BrimMenuBarItem.1")
            StatusItemPlacementSupport.clearRememberedVisibility(in: statusDefaults)
            suite.expect(statusDefaults.double(forKey: gen1Position) == 280.0,
                   "clearing the remembered visibility keeps the arranged position")
            suite.expect(StatusItemPlacementSupport.placementGeneration(in: statusDefaults) == 1
                    && StatusItemPlacementSupport.mainAutosaveName(in: statusDefaults) == gen1Name,
                   "recovery leaves the item's identity alone, so reopening cannot churn it")
            suite.expect(statusDefaults.object(forKey: "NSStatusItem Visible BrimMenuBarItem.1") == nil
                    && statusDefaults.object(forKey: "NSStatusItem VisibleCC BrimMenuBarItem.1") == nil,
                   "clearing the remembered visibility drops both spellings macOS has used")

            // Giving the spot up is what an explicit recovery escalates to,
            // and only after keeping it has failed.
            suite.expect(statusDefaults.object(forKey: gen1Position) == nil
                    || statusDefaults.double(forKey: gen1Position) == 280.0,
                   "only the identity reset gives up a saved position")
            // Leave orphan keys for older generations the way a long-running
            // install accumulates them, then confirm a bump sweeps them.
            statusDefaults.set(11.0, forKey: "NSStatusItem Preferred Position BrimMenuBarItem")
            statusDefaults.set(false, forKey: "NSStatusItem Visible BrimMenuBarItem")
            statusDefaults.set(false, forKey: "NSStatusItem VisibleCC BrimMenuBarItem.1")
            let metricPosition = "NSStatusItem Preferred Position BrimMetric.cpu"
            statusDefaults.set(42.0, forKey: metricPosition)
            StatusItemPlacementSupport.bumpPlacementGeneration(in: statusDefaults)
            suite.expect(statusDefaults.object(forKey: gen1Position) == nil
                    && statusDefaults.object(forKey: "NSStatusItem Preferred Position BrimMenuBarItem") == nil
                    && statusDefaults.object(forKey: "NSStatusItem Visible BrimMenuBarItem") == nil
                    && statusDefaults.object(forKey: "NSStatusItem VisibleCC BrimMenuBarItem.1") == nil
                    && StatusItemPlacementSupport.mainAutosaveName(in: statusDefaults)
                        == "BrimMenuBarItem.2"
                    && statusDefaults.object(forKey: "NSStatusItem Preferred Position BrimMenuBarItem.2") == nil,
                   "the identity reset gives the saved position up and sweeps orphaned identities")
            suite.expect(statusDefaults.double(forKey: metricPosition) == 42.0,
                   "recovering the main item leaves metric-item positions alone")
            statusDefaults.set(StatusItemPlacementSupport.maxPlacementGeneration,
                               forKey: DefaultsKey.statusItemPlacementGeneration)
            statusDefaults.set(false, forKey: "NSStatusItem Visible BrimMenuBarItem.9999")
            StatusItemPlacementSupport.bumpPlacementGeneration(in: statusDefaults)
            suite.expect(StatusItemPlacementSupport.mainAutosaveName(in: statusDefaults) == "BrimMenuBarItem.1"
                    && statusDefaults.object(forKey: "NSStatusItem Visible BrimMenuBarItem.9999") == nil
                    && statusDefaults.double(forKey: metricPosition) == 42.0,
                   "generation wrap clears old main-item state without touching metric placements")
            suite.expect(StatusItemAnchorSupport.isSettlingStatusFrame(CGRect(x: 0, y: 0, width: 36, height: 0)),
                   "a newborn status window with zero height is still settling")
            suite.expect(StatusItemAnchorSupport.isSettlingStatusFrame(nil),
                   "a status item without a window yet is still settling")
            suite.expect(!StatusItemAnchorSupport.isSettlingStatusFrame(CGRect(x: 2098, y: 1410, width: 36, height: 30)),
                   "a real on-bar frame is not settling")
            suite.expect(StatusItemPlacementSupport.shouldKeepWaitingForSettlement(
                       isOnScreen: false, isSettling: true, settlingGraceLeft: 3),
                   "settling frames keep the recovery waiting instead of declaring failure")
            suite.expect(!StatusItemPlacementSupport.shouldKeepWaitingForSettlement(
                        isOnScreen: false, isSettling: true, settlingGraceLeft: 0),
                   "settling grace eventually ends so recovery can escalate")
            suite.expect(!StatusItemPlacementSupport.shouldKeepWaitingForSettlement(
                        isOnScreen: true, isSettling: false, settlingGraceLeft: 3),
                   "an on-screen icon does not keep waiting")
            statusDefaults.removePersistentDomain(forName: statusPlacementSuite)
        }

        // MARK: An item macOS never placed is not "on screen" (issue #1394)

        // Measured on macOS 26 with the app switched off under System Settings
        // > Menu Bar > "Allow in the Menu Bar": AppKit builds the status window
        // at the bottom-left origin of the main display (AX reports it at
        // -1,1295 38x24) and never moves it. That rectangle intersects the
        // screen, which is all the recovery used to ask, so it logged
        // "appeared" for an icon nobody could see and never said why.
        let tahoeMain = CGRect(x: 0, y: 0, width: 2304, height: 1296)
        let tahoePortrait = CGRect(x: -1080, y: -173, width: 1080, height: 1920)
        let tahoeScreens = [tahoeMain, tahoePortrait]
        let unplacedFrame = CGRect(x: -1, y: -23, width: 38, height: 24)
        suite.expect(tahoeMain.intersects(unplacedFrame),
               "the unplaced frame does intersect the main screen, which is why intersection alone passed it")
        suite.expect(!StatusItemAnchorSupport.isSettlingStatusFrame(unplacedFrame),
               "the unplaced frame has real size, so the settling grace does not cover it")
        suite.expect(!StatusItemPlacementSupport.isPlacedStatusFrame(unplacedFrame, screenFrames: tahoeScreens),
               "a status window parked at the bottom-left origin is not a placed icon")
        suite.expect(StatusItemPlacementSupport.isPlacedStatusFrame(CGRect(x: 1792, y: 1269, width: 38, height: 24),
                                                                    screenFrames: tahoeScreens),
               "the same item placed in the main display's menu bar is")
        suite.expect(StatusItemPlacementSupport.isPlacedStatusFrame(CGRect(x: -900, y: 1710, width: 38, height: 24),
                                                                    screenFrames: tahoeScreens),
               "a placement in the portrait display's own menu bar counts too")
        suite.expect(!StatusItemPlacementSupport.isPlacedStatusFrame(CGRect(x: 1792, y: 1269, width: 0, height: 0),
                                                                     screenFrames: tahoeScreens),
               "a sizeless frame is not a placement")
        let iconIsOnScreenCode = stripCommentLines((statusAnchorAppDelegateSource
            .components(separatedBy: "private func iconIsOnScreen() -> Bool {").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        suite.expect(iconIsOnScreenCode.contains("StatusItemPlacementSupport.isPlacedStatusFrame("),
               "the recovery judges placement by the menu bar band, not by screen intersection")
        suite.expect(iconIsOnScreenCode.contains("statusItem.isVisible == true"),
               "a hidden item never counts as on screen, whatever frame its window kept")
        // An item the app keeps out of the bar for Dynamic Island is not
        // missing, and a rebuild on reopen could strand the panel's anchor.
        let reopenCode = stripCommentLines((statusAnchorAppDelegateSource
            .components(separatedBy: "func applicationShouldHandleReopen(").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        suite.expect(reopenCode.contains("mainItemHiddenByChoice != true, !iconIsOnScreen()"),
               "reopening the app leaves an item hidden by choice alone and opens Settings")
        // macOS 27's Siri app reopens running apps on almost every interaction;
        // only a reopen the person asked for may rebuild the icon or open anything.
        let reopenJudged = reopenCode.range(of: "guard ReopenRequestSupport.isPersonOpeningApp(")
        let reopenRebuild = reopenCode.range(of: "recreateStatusItem()")
        suite.expect(reopenJudged != nil && reopenRebuild != nil
                     && reopenJudged!.lowerBound < reopenRebuild!.lowerBound
                     && reopenCode.contains("ReopenRequestSupport.currentSender()"),
               "reopening judges who asked before it touches the icon, the panel or Settings")
        typealias ReopenSender = ReopenRequestSupport.Sender
        let personReopens: [(ReopenSender?, String)] = [
            (ReopenSender(bundleIdentifier: "com.apple.finder",
                          executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                          isApplication: true), "Finder"),
            (ReopenSender(bundleIdentifier: "com.apple.dock",
                          executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                          isApplication: true), "the Dock"),
            (ReopenSender(bundleIdentifier: "com.apple.Spotlight", executablePath: nil,
                          isApplication: true), "Spotlight"),
            // On macOS 27 the search field opened with Command-Space lives in the Siri app.
            (ReopenSender(bundleIdentifier: "com.apple.campo",
                          executablePath: "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI",
                          isApplication: true), "the macOS 27 search field"),
            (ReopenSender(bundleIdentifier: "com.apple.apps.launcher", executablePath: nil,
                          isApplication: true), "the Apps launcher"),
            (ReopenSender(bundleIdentifier: "com.example.launcher",
                          executablePath: "/Applications/Launcher.app/Contents/MacOS/Launcher",
                          isApplication: true), "a third-party launcher"),
            (ReopenSender(bundleIdentifier: "com.example.ShortcutLauncher", executablePath: nil,
                          isApplication: true), "another developer's app named after shortcuts"),
            (ReopenSender(bundleIdentifier: nil, executablePath: nil, isApplication: false),
             "open(1), gone by the time the event is read"),
            (ReopenSender(bundleIdentifier: nil, executablePath: "/usr/bin/osascript", isApplication: false),
             "a script run in Terminal"),
            (nil, "an event without a sender"),
        ]
        for (sender, source) in personReopens {
            suite.expect(ReopenRequestSupport.isPersonOpeningApp(sender),
                         "reopening from \(source) still brings the app back")
        }
        let automaticReopens: [(ReopenSender, String)] = [
            (ReopenSender(bundleIdentifier: "com.apple.WorkflowKit.BackgroundShortcutRunner",
                          executablePath: "/System/Library/PrivateFrameworks/WorkflowKit.framework/XPCServices/"
                              + "BackgroundShortcutRunner.xpc/Contents/MacOS/BackgroundShortcutRunner",
                          isApplication: true), "the Shortcuts action runner"),
            (ReopenSender(bundleIdentifier: nil,
                          executablePath: "/System/Library/PrivateFrameworks/WorkflowKit.framework/XPCServices/"
                              + "BackgroundShortcutRunner.xpc/Contents/MacOS/BackgroundShortcutRunner",
                          isApplication: false), "the same runner before LaunchServices lists it"),
            (ReopenSender(bundleIdentifier: "com.apple.shortcuts", executablePath: nil,
                          isApplication: true), "the Shortcuts app"),
            (ReopenSender(bundleIdentifier: "com.apple.Siri", executablePath: nil,
                          isApplication: true), "Siri"),
            (ReopenSender(bundleIdentifier: nil, executablePath: "/usr/libexec/linkd",
                          isApplication: false), "the App Intents daemon"),
            (ReopenSender(bundleIdentifier: nil,
                          executablePath: "/System/Library/PrivateFrameworks/VoiceShortcuts.framework/Versions/A/"
                              + "Support/siriactionsd",
                          isApplication: false), "Siri's actions daemon"),
            (ReopenSender(bundleIdentifier: nil,
                          executablePath: "/System/Library/PrivateFrameworks/IntelligenceFlowRuntime.framework/"
                              + "Versions/A/intelligenceflowd",
                          isApplication: false), "an Apple Intelligence service"),
        ]
        for (sender, source) in automaticReopens {
            suite.expect(!ReopenRequestSupport.isPersonOpeningApp(sender),
                         "a reopen sent by \(source) opens nothing")
        }
        suite.expect(ReopenRequestSupport.logName(ReopenSender(bundleIdentifier: nil, executablePath: "/usr/libexec/linkd",
                                                               isApplication: false)) == "linkd"
                     && ReopenRequestSupport.logName(ReopenSender(bundleIdentifier: "com.apple.finder",
                                                                  executablePath: "/System/Library/CoreServices/Finder.app",
                                                                  isApplication: true)) == "com.apple.finder",
               "the log names the sender by bundle identifier, or by executable without its path")
        let reshowCode = stripCommentLines((statusAnchorAppDelegateSource
            .components(separatedBy: "func reshowStatusItem() {").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        suite.expect(reshowCode.contains("DefaultsKey.menuBarHideIconWithMetrics")
                     && reshowCode.contains("DefaultsKey.notchHidesMenuBarIcon"),
               "Show menu bar icon turns off both ways of hiding it")

        // macOS 26 lets the person switch an app's menu bar items off per app,
        // and remembers the choice in Control Center's group container. The
        // app cannot override it, so recovery must recognise it and say so
        // instead of resetting the item's identity for nothing.
        func tracked(_ bundleID: String, allowed: Bool?) -> [[String: Any]] {
            var entry: [String: Any] = ["location": ["bundle": ["_0": bundleID]],
                                        "menuItemLocations": [["bundle": ["_0": bundleID]]]]
            if let allowed { entry["isAllowed"] = allowed }
            return [["bundle": ["_0": bundleID]], entry]
        }
        let trackedApplications: [Any] = tracked("com.lowtechguys.Clop", allowed: true)
            + tracked("com.roblesconsulting.brim", allowed: false)
            + tracked("com.roblesconsulting.brim.dev", allowed: true)
            + tracked("com.example.legacy", allowed: nil)
        suite.expect(MenuBarAllowanceSupport.allowance(forBundleID: "com.roblesconsulting.brim",
                                                       trackedApplications: trackedApplications) == .disallowed,
               "an app switched off under Allow in the Menu Bar reads as disallowed")
        suite.expect(MenuBarAllowanceSupport.allowance(forBundleID: "com.roblesconsulting.brim.dev",
                                                       trackedApplications: trackedApplications) == .allowed,
               "a sibling bundle id with its own entry does not bleed over")
        suite.expect(MenuBarAllowanceSupport.allowance(forBundleID: "com.example.legacy",
                                                       trackedApplications: trackedApplications) == .unknown,
               "an entry without the flag is unknown, never a verdict")
        suite.expect(MenuBarAllowanceSupport.allowance(forBundleID: "com.example.absent",
                                                       trackedApplications: trackedApplications) == .unknown,
               "an app Control Center has never tracked is unknown")
        suite.expect(MenuBarAllowanceSupport.allowance(forBundleID: "com.roblesconsulting.brim",
                                                       trackedApplications: ["garbage", 3]) == .unknown,
               "a malformed store is unknown rather than a crash or a verdict")
        // The on-disk shape: an outer plist whose trackedApplications value is
        // itself a binary plist, serialized as data.
        let innerData = try? PropertyListSerialization.data(fromPropertyList: trackedApplications,
                                                            format: .binary, options: 0)
        let outerData = innerData.flatMap {
            try? PropertyListSerialization.data(fromPropertyList: ["trackedApplications": $0,
                                                                   "showSpotlight": false],
                                                format: .binary, options: 0)
        }
        suite.expect(outerData.map {
                MenuBarAllowanceSupport.allowance(forBundleID: "com.roblesconsulting.brim", groupContainerPlist: $0)
            } == .disallowed,
               "the nested Control Center store decodes down to the per-app verdict")
        suite.expect(MenuBarAllowanceSupport.allowance(forBundleID: "com.roblesconsulting.brim",
                                                       groupContainerPlist: Data([0x00, 0x01])) == .unknown,
               "an unreadable store is unknown")
        let verifyIconCode = stripCommentLines((statusAnchorAppDelegateSource
            .components(separatedBy: "private func verifyIconReappeared(").last ?? "")
            .components(separatedBy: "\n    }").first ?? "")
        suite.expect(verifyIconCode.contains("MenuBarAllowanceSupport.currentAllowance(")
                    && verifyIconCode.contains("menuBarIconDisallowedBody"),
               "recovery names the Allow in the Menu Bar setting instead of blaming a full bar")
        let allowanceCheck = verifyIconCode.range(of: "MenuBarAllowanceSupport.currentAllowance(")
        let identityReset = verifyIconCode.range(of: "resetStatusItemPlacementIdentity()")
        suite.expect(allowanceCheck != nil && identityReset != nil
                    && allowanceCheck!.lowerBound < identityReset!.lowerBound,
               "the setting is checked before the identity reset burns the arranged spot")
        suite.expect(!Strings.enUS.menuBarIconDisallowedBody.isEmpty
                    && Strings.enUS.menuBarIconDisallowedBody.contains("Allow in the Menu Bar"),
               "the hint names the System Settings switch by its own label")
        suite.expect(registeredDefaults[DefaultsKey.panelShowKeepAwake] as? Bool == true,
               "Keep Awake panel section is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.panelShowUtilities] as? Bool == true,
               "Utilities panel section is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.panelShowControls] as? Bool == true,
               "Quick Controls panel section is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorInterval] as? Int == 2,
               "monitor default interval stays at 2 seconds")
        suite.expect(registeredDefaults[DefaultsKey.monitorShowDisk] as? Bool == true,
               "disk monitor panel section is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorSysAlerts] as? Bool == true,
               "system alert controls are shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorSysConnectedDevices] as? Bool == true,
               "the System card's connected devices row is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorSysCPUCores] as? Bool == true,
               "the CPU row's per-core bars are shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorGraphDisk] as? Bool == true,
               "disk monitor graph is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorNetApps] as? Bool == true,
               "network app usage block is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorNetAddresses] as? Bool == true,
               "local address block is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorDiskUsage] as? Bool == true,
               "disk usage block is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorDiskActivity] as? Bool == true,
               "disk activity block is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorDiskSMART] as? Bool == true,
               "disk SMART block is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorDiskProtection] as? Bool == true,
               "disk protection block is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorDiskTools] as? Bool == true,
               "disk tools block is shown by default")
        suite.expect(registeredDefaults[DefaultsKey.temperatureUnit] as? String == TemperatureUnit.celsius.rawValue,
               "temperature defaults to Celsius")
        suite.expect(registeredDefaults[DefaultsKey.menuBarCPUTemperature] as? Bool == false,
               "menu bar CPU temperature is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarGPUTemperature] as? Bool == false,
               "menu bar GPU temperature is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarBatteryTemperature] as? Bool == false,
               "menu bar battery temperature is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarBatteryTime] as? Bool == false,
               "menu bar battery time is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarDiskUsage] as? Bool == false,
               "menu bar disk usage is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarDiskActivity] as? Bool == false,
               "menu bar disk activity is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarPeripheralBattery] as? Bool == false,
               "menu bar peripheral battery is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarFanSpeed] as? Bool == false,
               "menu bar fan speed is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarMetricOrder] as? String
               == "cpu,cpuTemperature,gpu,gpuTemperature,memory,battery,batteryTime,batteryTemperature,peripheralBattery,network,diskUsage,diskActivity,connectedDevices,power,fanSpeed",
               "menu bar metric order keeps temperature sensors next to their components and disk near live I/O")
        suite.expect(registeredDefaults[DefaultsKey.menuBarCombineTemperatures] as? Bool == true,
               "menu bar combines usage and temperature by default")
        suite.expect(registeredDefaults[DefaultsKey.menuBarSeparateMetrics] as? Bool == false,
               "separate menu bar metric items are opt-in")
        suite.expect(registeredDefaults[DefaultsKey.menuBarNetworkUploadFirst] as? Bool == false,
               "network menu bar upload-first layout is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.networkSpeedUnit] as? String == NetworkSpeedUnit.bytes.rawValue,
               "network speeds keep bytes per second by default")
        suite.expect(registeredDefaults[DefaultsKey.menuBarLabelStyle] as? String == "compact",
               "menu bar label style defaults to compact")
        suite.expect(registeredDefaults[DefaultsKey.menuBarMemoryStyle] as? String == "percent",
               "memory menu bar style defaults to percent")
        suite.expect(registeredDefaults[DefaultsKey.monitorPwrTimeRemaining] as? Bool == true,
               "battery time is shown in the Power panel by default")
        suite.expect(registeredDefaults[DefaultsKey.monitorPwrPeripherals] as? Bool == false,
               "peripheral batteries stay out of the Power card until turned on")
        let peripheralsSuite = "brim.tests.powerPeripherals.\(UUID().uuidString)"
        if let peripheralsDefaults = UserDefaults(suiteName: peripheralsSuite) {
            peripheralsDefaults.removePersistentDomain(forName: peripheralsSuite)
            peripheralsDefaults.set(false, forKey: DefaultsKey.menuBarPeripheralBattery)
            Defaults.migratePowerPeripheralsVisibility(in: peripheralsDefaults)
            suite.expect(peripheralsDefaults.object(forKey: DefaultsKey.monitorPwrPeripherals) as? Bool == false,
                   "an update with the menu bar item off starts no peripheral reads in Power")
            peripheralsDefaults.set(true, forKey: DefaultsKey.menuBarPeripheralBattery)
            Defaults.migratePowerPeripheralsVisibility(in: peripheralsDefaults)
            suite.expect(!peripheralsDefaults.bool(forKey: DefaultsKey.monitorPwrPeripherals),
                   "turning on the menu bar item later leaves the Power choice alone")
            peripheralsDefaults.removePersistentDomain(forName: peripheralsSuite)
            peripheralsDefaults.set(true, forKey: DefaultsKey.menuBarPeripheralBattery)
            Defaults.migratePowerPeripheralsVisibility(in: peripheralsDefaults)
            suite.expect(peripheralsDefaults.bool(forKey: DefaultsKey.monitorPwrPeripherals),
                   "an update keeps peripheral batteries in Power for menu bar users")
            peripheralsDefaults.set(false, forKey: DefaultsKey.menuBarPeripheralBattery)
            Defaults.migratePowerPeripheralsVisibility(in: peripheralsDefaults)
            suite.expect(peripheralsDefaults.bool(forKey: DefaultsKey.monitorPwrPeripherals),
                   "hiding the menu bar item later leaves the Power choice alone")
            peripheralsDefaults.removePersistentDomain(forName: peripheralsSuite)
            Defaults.migratePowerPeripheralsVisibility(in: peripheralsDefaults)
            suite.expect(peripheralsDefaults.object(forKey: DefaultsKey.monitorPwrPeripherals) as? Bool == false,
                   "a fresh install keeps peripheral batteries out of Power")
            peripheralsDefaults.removePersistentDomain(forName: peripheralsSuite)
        } else {
            suite.expect(false, "peripheral visibility migration has isolated preferences")
        }
        let globalShortcutValues = GlobalShortcutRole.allCases
            .compactMap { registeredDefaults[$0.storageKey] as? String }
        // Two features shipping the same combination means one of them is dead
        // on arrival: the second registration is simply refused by the system,
        // and which one loses depends on the order they happen to sync in.
        suite.expect(Set(globalShortcutValues).count == globalShortcutValues.count,
               "no two features ship the same default combination")
        suite.expect(globalShortcutValues.count == GlobalShortcutRole.allCases.count,
               "every role ships with a default combination registered")
        suite.expect(GlobalShortcut(keyCode: Int64(kVK_ISO_Section),
                              modifiers: [.control, .option, .command]).isValid,
               "the extra ISO key (paragraph/caret above Tab) is recordable as a shortcut")

        for fallback in ["", " \n", "https://example.com/a.png", "data:image/png;base64,AAAA",
                         "blob:https://example.com/1", "IMG_1234.HEIC", "photo.jpeg", "clip.mp4", "scan.pdf"] {
            suite.expect(QuickToolsSupport.isMediaTextFallback(fallback),
                         "'\(fallback)' is the text a lone picture or clip carries")
        }
        for text in ["Total", "Total:", "1.2.3", "3.14", "e.g.", "Item\tQty\nA\t1", "see https://example.com",
                     "two words", "U.S.", "example.com", "2.4GHz", "12.5kg", "config.yaml", "john@example.com"] {
            suite.expect(!QuickToolsSupport.isMediaTextFallback(text),
                         "'\(text)' is copied text that still pastes plain")
        }
        // Paste plain delegates only to the universal ⌥⇧⌘V equivalent
        // (shift = 1, option = 2 in the AX modifier mask); anything else in
        // an app's menus is some other edit command and must not be pressed.
        suite.expect(QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "V",
                                                        modifierMask: 3,
                                                        isEnabled: true),
               "V with shift+option is an app's own matching-style paste")
        suite.expect(QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "v",
                                                        modifierMask: 3,
                                                        isEnabled: true),
               "the command character match ignores case")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "V",
                                                         modifierMask: 0,
                                                         isEnabled: true),
               "plain ⌘V is the regular paste, never pressed as match style")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "V",
                                                         modifierMask: 1,
                                                         isEnabled: true),
               "⇧⌘V alone is a different command in several apps")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "V",
                                                         modifierMask: 3 | 4,
                                                         isEnabled: true),
               "a control variant is not the matching-style paste")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "V",
                                                         modifierMask: 3 | 8,
                                                         isEnabled: true),
               "an equivalent without the command key does not qualify")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "C",
                                                         modifierMask: 3,
                                                         isEnabled: true),
               "other command characters never match")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: nil,
                                                         modifierMask: 3,
                                                         isEnabled: true),
               "an item with no key equivalent never matches")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "V",
                                                         modifierMask: nil,
                                                         isEnabled: true),
               "an unreadable modifier mask never matches")
        suite.expect(!QuickToolsSupport.isMatchStyleEquivalent(commandCharacter: "V",
                                                         modifierMask: 3,
                                                         isEnabled: false),
               "a disabled item is left alone so the fallback paste still runs")

        // Launcher grid: 8 items in 3 columns (rows of 3, 3, 2).
        suite.expect(QuickToolsSupport.gridIndex(after: 0, count: 8, columns: 3, direction: .right) == 1,
               "launcher grid moves right within a row")
        suite.expect(QuickToolsSupport.gridIndex(after: 2, count: 8, columns: 3, direction: .right) == 2,
               "launcher grid does not wrap at the row's right edge")
        suite.expect(QuickToolsSupport.gridIndex(after: 3, count: 8, columns: 3, direction: .left) == 3,
               "launcher grid does not wrap at the row's left edge")
        suite.expect(QuickToolsSupport.gridIndex(after: 1, count: 8, columns: 3, direction: .down) == 4,
               "launcher grid moves down one row")
        suite.expect(QuickToolsSupport.gridIndex(after: 7, count: 8, columns: 3, direction: .down) == 7,
               "launcher grid stays put when there is no row below")
        suite.expect(QuickToolsSupport.gridIndex(after: 4, count: 8, columns: 3, direction: .up) == 1,
               "launcher grid moves up one row")
        suite.expect(QuickToolsSupport.gridIndex(after: 6, count: 8, columns: 3, direction: .right) == 7,
               "launcher grid moves right in the last partial row")
        suite.expect(QuickToolsSupport.gridIndex(after: 99, count: 8, columns: 3, direction: .left) == 6,
               "launcher grid clamps an out-of-range index")
        suite.expect(QuickToolsSupport.gridIndex(after: 0, count: 0, columns: 3, direction: .down) == 0,
               "launcher grid survives an empty item list")

        // The shared take-over works on raw WindowServer ids. Same transition
        // rule as the switcher had: suppress only what is enabled now, restore
        // only what we own and no longer want.
        suite.expect(SystemShortcutTakeoverSupport.transition(from: [], to: [1, 2, 30], currentlyEnabled: [1, 30])
               == SystemShortcutTransition(suppress: [1, 30], restore: [])
               && SystemShortcutTakeoverSupport.transition(from: [1, 30], to: [], currentlyEnabled: [])
               == SystemShortcutTransition(suppress: [], restore: [1, 30]),
               "the shared take-over suppresses only enabled ids and restores only owned ones")
        suite.expect(SystemShortcutTakeoverSupport.marker([27, 28, 30]) == [27, 28, 30]
               && SystemShortcutTakeoverSupport.marker(nil).isEmpty
               && SystemShortcutTakeoverSupport.marker([99_999_999_999]).isEmpty,
               "the saved marker reads back its ids, dropping anything that is not an id")
        // #1357's contracts, carried by the shared rule. Launch gives back
        // every id the marker still holds: a feature that is off claims none
        // of them, so all of them are restored.
        let savedMarker = SystemShortcutTakeoverSupport.marker([27, 28, 220])
        suite.expect(SystemShortcutTakeoverSupport.recoveryTransition(from: savedMarker, keeping: [])
               == SystemShortcutTransition(suppress: [], restore: [27, 28, 220]),
               "launch gives back a marker left by an earlier run")
        var recoveryWrites: [Int32] = []
        let recordRecoveryWrite: (Int32, Bool) -> Bool = { id, _ in
            recoveryWrites.append(id)
            return true
        }
        let cleanLaunchOwnership = SystemShortcutTakeoverSupport.apply(
            SystemShortcutTakeoverSupport.recoveryTransition(from: [], keeping: [1, 2, 27, 220]),
            owned: [], setEnabled: recordRecoveryWrite, persist: { _ in })
        suite.expect(cleanLaunchOwnership.isEmpty && recoveryWrites.isEmpty,
               "clean launch leaves system shortcuts working until the replacement tap is live")
        let recoveredOwnership = SystemShortcutTakeoverSupport.apply(
            SystemShortcutTakeoverSupport.recoveryTransition(from: savedMarker, keeping: [1, 27, 220]),
            owned: savedMarker, setEnabled: recordRecoveryWrite, persist: { _ in })
        suite.expect(recoveredOwnership == [27, 220] && recoveryWrites == [28],
               "crash recovery gives back stale keys without toggling retained keys or taking new ones")
        // The switcher is not the only source by the time recovery runs: a
        // feature that claimed first holds its ids too, so launch keeps what
        // every source wants together rather than the switcher's ids alone.
        var earlyClaimWrites: [Int32] = []
        let earlyClaimOwnership = SystemShortcutTakeoverSupport.apply(
            SystemShortcutTakeoverSupport.recoveryTransition(
                from: [1, 28, 30],
                keeping: SystemShortcutTakeoverSupport.union(
                    of: ["switcher": [1], "keepAwakeShortcut": [30]])),
            owned: [1, 28, 30],
            setEnabled: { id, _ in
                earlyClaimWrites.append(id)
                return true
            },
            persist: { _ in })
        suite.expect(earlyClaimOwnership == [1, 30] && earlyClaimWrites == [28],
               "launch keeps a claim made before recovery ran alongside the switcher's ids")
        // Say the WindowServer refused 28: `apply` leaves it in the marker, so
        // every later transition asks for it again and the give-back finishes
        // at the next take-over or in the next process.
        suite.expect(SystemShortcutTakeoverSupport.transition(from: [28], to: [1], currentlyEnabled: [1])
               == SystemShortcutTransition(suppress: [1], restore: [28]),
               "an id whose give-back failed stays owned and is retried while another key is taken over")
        suite.expect(SystemShortcutTakeoverSupport.transition(from: [1, 28], to: [], currentlyEnabled: [])
               == SystemShortcutTransition(suppress: [], restore: [1, 28]),
               "a marker that survived a failed give-back is retried in full by the next process")
        suite.expect(SystemShortcutTakeoverSupport.transition(from: [], to: [], currentlyEnabled: [1, 28])
               == SystemShortcutTransition(suppress: [], restore: []),
               "an id given back successfully leaves the marker and is never switched on again")
        // The pass itself, against a fake table: the marker must be on disk
        // before a key is switched off, a refused disable must take the key
        // back out, and a refused enable must leave it in for the retry.
        var fakeEnabled: Set<Int32> = [1, 27]
        var refused: Set<Int32> = []
        var markers: [Set<Int32>] = []
        var writeAheadMissing = false
        let fakeSetEnabled: (Int32, Bool) -> Bool = { id, on in
            if !on, !(markers.last?.contains(id) ?? false) { writeAheadMissing = true }
            guard !refused.contains(id) else { return false }
            if on { fakeEnabled.insert(id) } else { fakeEnabled.remove(id) }
            return true
        }
        let record: (Set<Int32>) -> Void = { markers.append($0) }
        refused = [27]
        let afterRefusedDisable = SystemShortcutTakeoverSupport.apply(
            SystemShortcutTransition(suppress: [1, 27], restore: []), owned: [],
            setEnabled: fakeSetEnabled, persist: record)
        suite.expect(afterRefusedDisable == [1] && fakeEnabled == [27] && markers.last == [1]
               && markers.contains(where: { $0.contains(27) }),
               "a refused disable rolls the key back out of the marker it was written ahead into")
        refused = [1]
        let afterRefusedEnable = SystemShortcutTakeoverSupport.apply(
            SystemShortcutTransition(suppress: [], restore: [1]), owned: afterRefusedDisable,
            setEnabled: fakeSetEnabled, persist: record)
        suite.expect(afterRefusedEnable == [1] && !fakeEnabled.contains(1),
               "a refused enable keeps the key in the marker for the next pass to retry")
        refused = []
        suite.expect(SystemShortcutTakeoverSupport.apply(
                   SystemShortcutTransition(suppress: [], restore: [1]), owned: afterRefusedEnable,
                   setEnabled: fakeSetEnabled, persist: record).isEmpty && fakeEnabled == [1, 27],
               "the retry finishes the give-back")
        suite.expect(!writeAheadMissing, "ownership is persisted before every disable")

        // A claimed shortcut resolves to every live id that is exactly that
        // combination - the two screenshot rows share Shift-Command on different keys and
        // must not be confused; a disabled row still counts, `apply` sorts it out.
        let liveForClaims: [LiveSystemShortcut] = [
            LiveSystemShortcut(id: 28, shortcut: GlobalShortcut(keyCode: 20, modifiers: [.command, .shift]), enabled: true),
            LiveSystemShortcut(id: 30, shortcut: GlobalShortcut(keyCode: 21, modifiers: [.command, .shift]), enabled: true),
            LiveSystemShortcut(id: 64, shortcut: GlobalShortcut(keyCode: 49, modifiers: [.command]), enabled: false),
        ]
        suite.expect(SystemShortcutTakeoverSupport.ids(matching: GlobalShortcut(keyCode: 21, modifiers: [.command, .shift]),
                                                 in: liveForClaims) == [30]
               && SystemShortcutTakeoverSupport.ids(matching: GlobalShortcut(keyCode: 49, modifiers: [.command]),
                                                    in: liveForClaims) == [64]
               && SystemShortcutTakeoverSupport.ids(matching: .notchDefault, in: liveForClaims).isEmpty,
               "a claimed shortcut maps to exactly the live ids that equal it")
        suite.expect(SystemShortcutTakeoverSupport.union(of: ["first": [1, 2], "second": [30], "empty": []]) == [1, 2, 30]
               && SystemShortcutTakeoverSupport.union(of: [:]).isEmpty,
               "the service applies what every source wants, together")
        suite.expect(SystemShortcutTakeoverSupport.transition(from: [1, 30], to: [], currentlyEnabled: [])
               == SystemShortcutTransition(suppress: [], restore: [1, 30]),
               "quitting hands back every key any feature took over")
        // Launch recovery records the ids it kept as the switcher's own, so the
        // first claim of the launch - a row with no opt-in of its own resolves
        // to nothing - asks for those ids too and hands none of them back.
        suite.expect(SystemShortcutTakeoverSupport.transition(
                   from: [1, 2],
                   to: SystemShortcutTakeoverSupport.union(of: ["switcher": [1, 2]]),
                   currentlyEnabled: []) == SystemShortcutTransition(suppress: [], restore: []),
               "a claim with no opt-in leaves the marker launch recovery is holding alone")
        // A key already taken over is switched off in the live table, so the
        // table alone calls it free. What the recorder asks instead counts the
        // ids the service is holding as macOS's, and falls back to the table
        // for a key it is not holding.
        let areaShot = GlobalShortcut(keyCode: 21, modifiers: [.command, .shift])
        let liveWhileHeld: [LiveSystemShortcut] = [
            LiveSystemShortcut(id: 30, shortcut: areaShot, enabled: false),
            LiveSystemShortcut(id: 28, shortcut: GlobalShortcut(keyCode: 20, modifiers: [.command, .shift]), enabled: true),
        ]
        let areaShotIsMacOS = SystemShortcutTakeoverSupport.conflictsWithMacOS(
            areaShot, liveEntries: liveWhileHeld, symbolicHotKeys: nil, held: [30])
        suite.expect(areaShotIsMacOS
               && !SystemShortcutTakeoverSupport.conflictsWithMacOS(
                   areaShot, liveEntries: liveWhileHeld, symbolicHotKeys: nil, held: [1, 2])
               && SystemShortcutTakeoverSupport.conflictsWithMacOS(
                   GlobalShortcut(keyCode: 20, modifiers: [.command, .shift]),
                   liveEntries: liveWhileHeld, symbolicHotKeys: nil, held: []),
               "a key this app is holding still counts as macOS's, and one it is not holding follows the live table")
        // The recorder's one rule for a combination macOS answers: ask unless the
        // user already agreed to exactly this key on this row; tidy the entry
        // once the row moves to a key macOS does not want.
        suite.expect(registeredDefaults[DefaultsKey.systemShortcutTakeOverKeys] == nil,
               "which shortcuts to take over is a preference")
    }
}
