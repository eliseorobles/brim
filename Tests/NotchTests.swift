// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreGraphics
import AppKit
import SwiftUI

enum NotchTests {
    private static func railContracts(_ suite: TestSuite) {
        let domain = "brim.tests.notch-fan-only"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        for feature in AppFeature.allCases { defaults.set(false, forKey: feature.availabilityKey) }
        suite.expect(!NotchModule.system.isAvailable(in: defaults), "System stays unavailable without an installed monitor")
        defaults.set(true, forKey: AppFeature.fanControl.availabilityKey)
        suite.expect(NotchModule.system.isAvailable(in: defaults)
                     && NotchSupport.systemCardCount(hasBattery: false, fans: 1, in: defaults) == 1,
                     "fan control alone makes its containing System page reachable")
        suite.expect(NotchModule.system.isAvailable(in: defaults)
                     && NotchSupport.systemCardCount(hasBattery: false, fans: 0, in: defaults) == 0,
                     "System remains reachable while waiting for the first fan sample")
        defaults.set(false, forKey: AppFeature.fanControl.availabilityKey)
        defaults.set(true, forKey: AppFeature.connectedDevices.availabilityKey)
        defaults.set(false, forKey: DefaultsKey.menuBarConnectedDevices)
        suite.expect(NotchModule.system.isAvailable(in: defaults)
                     && NotchSupport.systemCardCount(hasBattery: false, in: defaults) == 1,
                     "connected devices alone keeps its System page and card reachable with the menu bar widget off")
        defaults.set(false, forKey: AppFeature.connectedDevices.availabilityKey)
        suite.expect(!NotchModule.system.isAvailable(in: defaults)
                     && NotchSupport.systemCardCount(hasBattery: false, in: defaults) == 0,
                     "uninstalling connected devices removes its System page and card")

        suite.expect(NotchLayout.systemRowRanges(count: 7, width: 504) == [0..<3, 3..<5, 5..<7],
                     "seven System metrics fill balanced rows instead of leaving a nearly empty column")
        suite.expect(NotchLayout.systemRowRanges(count: 7, width: 304) == [0..<2, 2..<4, 4..<6, 6..<7],
                     "narrow System rows keep readable cards and a full-width last card")
        for width: CGFloat in [20, 304, 424, 504, 744] {
            for count in 0...9 {
                let rows = NotchLayout.systemRowRanges(count: count, width: width)
                suite.expect(rows.flatMap { Array($0) } == Array(0..<count),
                             "System preserves every metric exactly once in reading order")
                let capacity = NotchLayout.railCapacity(width: width, itemWidth: NotchLayout.systemCardWidth,
                                                       spacing: NotchLayout.rowSpacing)
                suite.expect(rows.allSatisfy { !$0.isEmpty && $0.count <= capacity },
                             "System rows fit the available width for every combination of enabled metrics")
            }
        }

        suite.expect(NotchLayout.railCapacity(width: 424, itemWidth: 76, spacing: 8) == 5
               && NotchLayout.railCapacity(width: 304, itemWidth: 76, spacing: 8) == 3
               && NotchLayout.railCapacity(width: 20, itemWidth: 76, spacing: 8) == 1
               && NotchLayout.railCapacity(width: .nan, itemWidth: 76, spacing: 8) == 1,
               "a rail fits whole columns of its width and never fewer than one")
        suite.expect(NotchLayout.railRows(count: 4, perRow: 5, rowHeight: 74, spacing: 8, height: 180) == 1
               && NotchLayout.railRows(count: 7, perRow: 5, rowHeight: 74, spacing: 8, height: 106) == 1
               && NotchLayout.railRows(count: 7, perRow: 5, rowHeight: 74, spacing: 8, height: 190) == 2
               && NotchLayout.railRows(count: 0, perRow: 0, rowHeight: 74, spacing: 8, height: 0) == 1
               && NotchLayout.railRows(count: 40, perRow: 5, rowHeight: 74, spacing: 8, height: .infinity) == 8,
               "rows follow the items that need them and stop where the height ends")
        suite.expect(NotchLayout.railHeight(rows: 1, rowHeight: 74, spacing: 8) == 74
               && NotchLayout.railHeight(rows: 3, rowHeight: 74, spacing: 8) == 238
               && NotchLayout.railHeight(rows: 0, rowHeight: 74, spacing: 8) == 74,
               "a rail's height is its rows and the gaps between them")
        suite.expect(NotchLayout.railColumns(count: 11, rows: 2) == 6
               && NotchLayout.railColumns(count: 8, rows: 2) == 4
               && NotchLayout.railColumns(count: 0, rows: 0) == 0
               && NotchLayout.railFits(columns: 6, itemWidth: 76, spacing: 8, width: 496)
               && !NotchLayout.railFits(columns: 6, itemWidth: 76, spacing: 8, width: 495),
               "a rail spreads its items over the fewest columns its rows allow and fits once they all do")
        let controls = NotchLayout.controls(shortcutCount: 4, width: 424, height: NotchLayout.compactContentHeight)
        suite.expect(controls == NotchControlsLayout(shortcutRows: 1)
               && controls.height == NotchLayout.shortcutHeight
               && controls.height < NotchLayout.compactContentHeight,
               "the default home page is one shortcut rail, shorter than the compact strip")
        let nineTiles = NotchLayout.controls(shortcutCount: 9, width: 424, height: 154)
        suite.expect(NotchLayout.controls(shortcutCount: 0, width: 424, height: 154) == NotchControlsLayout(shortcutRows: 0)
               && NotchLayout.controls(shortcutCount: 0, width: 424, height: 154).height == 0
               && nineTiles == NotchControlsLayout(shortcutRows: 2, shortcutRowSpacing: NotchLayout.shortcutLeastRowSpacing),
               "the smallest custom island closes the rail's rows to keep them, and rows nobody enabled cost nothing")
    }

    private static func presentationSpacingContracts(_ suite: TestSuite) {
        let screen = CGRect(x: -1470, y: 80, width: 1470, height: 956)
        for width in [360.0, 480, 560, 720] {
            for cameraHeight: CGFloat in [24, 32, 40, 64] {
                let geometry = NotchGeometry(screen: screen, safeAreaTop: cameraHeight, cameraWidth: 210,
                                             layout: .custom, customWidth: width, customHeight: 400)
                suite.expect(geometry.pageTopInset >= cameraHeight, "the page always begins below the physical camera")
                let area = geometry.activationArea(in: geometry.expanded, hasHeader: true,
                                                   compactActivity: false, expandedHeader: true)
                if width >= 480 {
                    suite.expect(geometry.headerCameraGap == 210 && geometry.headerTopInset == 0,
                                 "wide islands use the space beside the camera without reserving a blank top row")
                    suite.expect(area.width == 210 && area.height == cameraHeight
                                 && area.midX == geometry.expanded.width / 2,
                                 "the collapse target covers only the camera, leaving the row's controls clickable")
                } else {
                    suite.expect(geometry.headerCameraGap == 0 && geometry.headerTopInset >= cameraHeight,
                                 "narrow islands keep a complete usable row below the camera")
                }
                let content = geometry.contentSize(for: geometry.expandedSize(module: .system, systemCards: 1))
                let inset = NotchLayout.systemHoverInset(width: content.width)
                suite.expect((content.width - inset * 2) * 1.028 <= content.width
                             && NotchLayout.systemCardHeight * 1.028 <= NotchLayout.systemCardHeight + inset * 2,
                             "even a full-width system card can grow on hover inside its viewport")
            }
        }
        for layout: NotchSize in [.compact, .spacious] {
            let geometry = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 210, layout: layout)
            suite.expect(geometry.headerTopInset == 0 && geometry.headerCameraGap == 210,
                         "both presets place the top row beside the camera without a blank row above it")
            suite.expect(geometry.quickAccessCenterY - NotchQuickAccessLayout.diameter / 2 == 38,
                         "floating buttons keep six points of clearance below the menu bar in both presets")
        }
        let simulated = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, layout: .spacious)
        suite.expect(simulated.headerTopInset == 0 && simulated.headerCameraGap == 0,
                     "a display without a camera does not reserve a blank row above the open page's own")
        suite.expect(simulated.activationArea(in: simulated.expanded, hasHeader: true,
                                             compactActivity: false, expandedHeader: true).isEmpty,
                     "a simulated island's top row is never covered by an invisible collapse button")
        var bare = simulated
        bare.pageTop = .none
        suite.expect(bare.headerRowHeight == 0 && bare.headerTopInset == NotchLayout.bottomInset
                     && bare.pageTopInset == NotchLayout.bottomInset
                     && bare.activationArea(in: bare.expanded, hasHeader: true, compactActivity: false,
                                            expandedHeader: true).isEmpty,
                     "a page with nothing for the row starts as far from the top as it ends from the bottom")
    }

    /// The island names no page: its top row holds the page's own controls,
    /// wrapping the camera wherever each side keeps a 100-point wing, and a
    /// row below the camera elsewhere. A page with nothing for the row starts
    /// below the camera, or at the top of an island without one, and the
    /// player starts at the top of the row, wrapping the camera itself.
    private static func pageTopContracts(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        var geometries: [NotchGeometry] = []
        for camera: CGFloat in [180, 185, 208, 210, 224, 240] {
            for layout: NotchSize in [.compact, .spacious] {
                geometries.append(NotchGeometry(screen: screen, safeAreaTop: 37.5, cameraWidth: camera, layout: layout))
            }
            for width in stride(from: NotchSize.widthRange.lowerBound, through: NotchSize.widthRange.upperBound, by: 10) {
                geometries.append(NotchGeometry(screen: screen, safeAreaTop: 37.5, cameraWidth: camera,
                                                layout: .custom, customWidth: width))
            }
        }
        for geometry in geometries {
            let place = "beside a \(Int(geometry.cameraWidth))-point camera in a \(Int(geometry.expandedWidth))-point island"
            var aside = true, below = true, bands = true
            for module in NotchModule.allCases {
                var page = geometry
                page.pageTop = module.pageTop
                let wraps = page.contentWidth >= page.cameraWidth + NotchGeometry.pageBandSide * 2
                let band = NotchBand(geometry: page, contentWidth: page.contentWidth)
                if wraps {
                    aside = aside && page.headerCameraGap == geometry.cameraWidth && page.headerTopInset == 0
                        && page.headerRowHeight == max(page.cameraHeight, NotchLayout.headerHeight)
                        && page.pageTopInset == page.headerRowHeight + NotchLayout.spacing
                    bands = bands && band.besideCamera && band.side >= NotchGeometry.pageBandSide - NotchBand.cameraClearance
                } else {
                    below = below && page.headerCameraGap == 0 && page.headerTopInset == page.safeContentTop
                        && page.headerRowHeight == (module.pageTop == .row ? NotchLayout.headerHeight : 0)
                        && page.pageTopInset >= page.safeContentTop
                    bands = bands && !band.besideCamera && band.side == page.contentWidth
                }
                let size = page.expandedSize(module: module)
                bands = bands && page.contentSize(for: size).height
                    == size.height - page.pageTopInset - NotchLayout.bottomInset
            }
            suite.expect(aside, "every page's row wraps the camera where its sides fit \(place)")
            suite.expect(below, "every page's row takes the full width below the camera where its sides do not \(place)")
            suite.expect(bands, "the row's sides and the page below it add up \(place)")
        }
        // The report: a 1710 by 1112 point display with a 208 by 37.5 point camera, in the compact preset.
        var reported = NotchGeometry(screen: screen, safeAreaTop: 37.5, cameraWidth: 208)
        reported.pageTop = NotchModule.controls.pageTop
        suite.expect(reported.headerCameraGap == 208 && reported.headerTopInset == 0,
                     "Controls keeps its row beside a 208-point camera in the compact preset")
        for silhouette in NotchSilhouette.allCases {
            let plain = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, silhouette: silhouette)
            for module in NotchModule.allCases {
                var page = plain
                page.pageTop = module.pageTop
                let row = module.pageTop == .row
                suite.expect(page.headerCameraGap == 0 && page.headerRowHeight == (row ? NotchLayout.headerHeight : 0)
                             && page.headerTopInset == (row ? plain.headerTopInset : NotchLayout.bottomInset)
                             && page.pageTopInset == (row ? plain.pageTopInset : NotchLayout.bottomInset)
                             && page.activationArea(in: page.expandedSize(module: module), hasHeader: true,
                                                    compactActivity: false, expandedHeader: true).isEmpty,
                             "the \(module.rawValue) page's top in a \(silhouette.rawValue) island without a camera")
            }
        }
    }

    /// Under a preset each page takes the width it needs, up to the preset's:
    /// the home page its row of shortcuts, and lists the whole width. A width
    /// set by hand is the island's on every page, so a wider one makes the
    /// home page wider too.
    private static func pageWidthContracts(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let screens: [(CGFloat, CGFloat)] = [(0, 0), (156, 28), (179, 32), (185, 37.5), (210, 37.5), (224, 37.5)]
        for (camera, top) in screens {
            for layout: NotchSize in [.compact, .spacious] {
                var list = NotchGeometry(screen: screen, safeAreaTop: top, cameraWidth: camera, layout: layout,
                                         silhouette: camera == 0 ? .capsule : .notch)
                let chosen = list.expandedWidth
                list.pageTop = NotchModule.clipboard.pageTop
                list.pageContentWidth = NotchLayout.naturalContentWidth(.clipboard, controls: [], within: list.contentWidth)
                suite.expect(list.expandedWidth == chosen, "a list keeps the chosen width in \(layout)")
            }
        }
        let few: [NotchControlItem] = [.keepAwake, .speedTest, .panel]
        let five: [NotchControlItem] = [.keepAwake, .speedTest, .panel, .keepAwake, .speedTest]
        suite.expect(NotchLayout.naturalContentWidth(.controls, controls: few, within: 504) == NotchLayout.homeContentWidth,
                     "a short row of shortcuts keeps the home page's least width")
        let home = NotchLayout.naturalContentWidth(.controls, controls: five, within: 504)
        suite.expect(home == 5 * NotchLayout.shortcutWidth + 4 * NotchLayout.shortcutSpacing,
                     "the home page is as wide as its one row of shortcuts: \(home ?? 0)")
        suite.expect(NotchLayout.naturalContentWidth(.controls, controls: five, within: 300) == nil,
                     "a row of shortcuts that wraps takes the whole width")
        for (camera, top) in screens {
            for layout: NotchSize in [.compact, .spacious] {
                let base = NotchGeometry(screen: screen, safeAreaTop: top, cameraWidth: camera, layout: layout,
                                         silhouette: camera == 0 ? .capsule : .notch)
                let page = base.page(.controls, controls: few, sectionsButton: false)
                let expected = max(NotchLayout.homeContentWidth, camera > 0 ? camera + NotchGeometry.pageBandSide * 2 : 0)
                    + NotchLayout.horizontalInset * 2
                suite.expect(page.expandedWidth == min(base.expandedWidth, expected)
                             && (layout == .compact || page.expandedWidth < base.expandedWidth),
                             "the home page is no wider than its shortcuts need, around a \(Int(camera))-point camera in \(layout)")
            }
        }
        var handSet = true
        for (camera, top) in screens {
            for width in stride(from: NotchSize.widthRange.lowerBound, through: NotchSize.widthRange.upperBound, by: 20) {
                let base = NotchGeometry(screen: screen, safeAreaTop: top, cameraWidth: camera, layout: .custom,
                                         customWidth: width, silhouette: camera == 0 ? .capsule : .notch)
                for module in NotchModule.allCases {
                    for sectionsButton in [false, true] {
                        let page = base.page(module, controls: five, sectionsButton: sectionsButton)
                        handSet = handSet && page.expandedWidth == CGFloat(width)
                    }
                }
            }
        }
        suite.expect(handSet, "a width set by hand is the island's on every page")
        // The Layout tab previews the home page at the width the island opens
        // it at, never a preset's wider island around it.
        let editor = (try? String(contentsOfFile: "Sources/Brim/UI/Settings/NotchLayoutEditor.swift", encoding: .utf8)) ?? ""
        suite.expect(editor.contains("private var actualWidth: CGFloat { previewGeometry.expandedWidth }")
                     && editor.contains("return geometry.page(.controls, controls: NotchSupport.controls(),"),
                     "the Layout preview opens the home page as the island does")
    }

    /// Without a floating Explore button each page's row starts with the
    /// island's own way to the sections. A page with a width of its own grows
    /// by it beside a camera, up to the chosen width, so its controls keep
    /// the room they have while the button floats; and a page with nothing
    /// for the row still gets one for the button.
    private static func sectionsButtonContracts(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let home: [NotchControlItem] = [.keepAwake, .speedTest, .panel]
        let button = NotchBand.sectionsButtonRoom
        var sizes: [(NotchSize, Double)] = [(.compact, NotchSize.defaultWidth), (.spacious, NotchSize.defaultWidth)]
        sizes += stride(from: NotchSize.widthRange.lowerBound, through: NotchSize.widthRange.upperBound, by: 20).map { (.custom, $0) }
        var unchanged = true, widths = true, sides = true, reached = true, bare = true
        for camera: CGFloat in [0, 156, 170, 180, 185, 190, 200, 208, 210, 224] {
            for (size, custom) in sizes {
                let base = NotchGeometry(screen: screen, safeAreaTop: camera > 0 ? 32 : 0, cameraWidth: camera, layout: size,
                                         customWidth: custom, silhouette: camera > 0 ? .notch : .capsule)
                for module in NotchModule.allCases {
                    let floating = base.page(module, controls: home, sectionsButton: false)
                    let leading = base.page(module, controls: home, sectionsButton: true)
                    let floatingBand = NotchBand(geometry: floating, contentWidth: floating.contentWidth)
                    let band = NotchBand(geometry: leading, contentWidth: leading.contentWidth)
                    unchanged = unchanged && !floatingBand.sectionsButton
                        && floating.expandedWidth == {
                            var plain = base
                            plain.pageTop = module.pageTop
                            plain.pageContentWidth = NotchLayout.naturalContentWidth(module, controls: home, within: base.contentWidth)
                            return plain.expandedWidth
                        }()
                    sides = sides && band.sectionsButton
                    // Every page leads to the sections from a row it has.
                    reached = reached && leading.headerRowHeight > 0
                    if module.pageTop == .none, !floatingBand.besideCamera {
                        // A page with nothing for the row starts below the button's row,
                        // keeping the content it has while the button floats.
                        let content = { (page: NotchGeometry) -> CGFloat in page.contentSize(for: page.expandedSize(module: module)).height }
                        bare = bare && floating.headerRowHeight == 0 && leading.headerRowHeight == NotchLayout.headerHeight
                            && leading.pageTopInset == leading.headerTopInset + NotchLayout.headerHeight + NotchLayout.spacing
                            && (size == .custom || content(leading) == content(floating))
                    }
                    if band.besideCamera, floating.pageContentWidth != nil {
                        // Each side past the button keeps what a page's row keeps
                        // beside a camera, unless the chosen width stops the island.
                        widths = widths && leading.expandedWidth <= floating.expandedWidth + button * 2
                            && (band.side - button >= NotchGeometry.pageBandSide - NotchBand.cameraClearance
                                || leading.expandedWidth == base.expandedWidth)
                    } else {
                        // Lists keep the chosen width, and a full row holds the button.
                        widths = widths && leading.expandedWidth == floating.expandedWidth
                    }
                }
            }
        }
        suite.expect(unchanged, "with Explore floating the row and every page's width stay as they were")
        suite.expect(sides, "every page starts its row with the sections button, and its controls follow it")
        suite.expect(reached, "every page leads to the sections without the floating Explore button")
        suite.expect(bare, "a page with nothing for the row gets one for the sections button where no camera's row holds it")
        suite.expect(widths,
                     "a page with a width of its own grows by the sections button beside a camera, up to the chosen width; lists and full rows keep theirs")
    }

    /// The island and its Layout preview lay the home page's rail out the
    /// same way: gaps closed before it scrolls, rows spaced as the layout says.
    private static func homeRailContracts(_ suite: TestSuite) {
        for path in ["Sources/Brim/UI/Notch/NotchControlsView.swift", "Sources/Brim/UI/Settings/NotchLayoutEditor.swift"] {
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            suite.expect(source.components(separatedBy: "leastSpacing: NotchLayout.shortcutLeastSpacing").count == 2,
                         "the home page's rail closes its gaps before it scrolls in \(path)")
        }
        for (path, call) in [("Sources/Brim/UI/Notch/NotchControlsView.swift", "rowSpacing: layout.shortcutRowSpacing"),
                             ("Sources/Brim/UI/Settings/NotchLayoutEditor.swift", "rowSpacing: controls.shortcutRowSpacing")] {
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            suite.expect(source.components(separatedBy: call).count == 2,
                         "the home page's rail spaces its rows as its layout does in \(path)")
        }
    }

    private static func noticeLayoutContracts(_ suite: TestSuite) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let screen = CGRect(x: -1470, y: 100, width: 1470, height: 956)
        for language in AppLanguage.allCases {
            let text = FeatureStrings.notch(language)
            let notices = [text.onBattery, text.charging, text.charged, text.lowBattery].map {
                NotchNotice(event: .battery, title: $0, detail: "100%", symbol: "battery.100percent.bolt")
            } + [NotchNotice(event: .inputSource, title: "ABC", detail: "U.S. International – PC", symbol: "keyboard")]
            for physical in [false, true] {
                for height: CGFloat in [16, 24, 32, 40, 64] {
                    let geometry = NotchGeometry(screen: screen, safeAreaTop: physical ? height : 0,
                                                 cameraWidth: physical ? 180 : 0, menuBarHeight: height)
                    for notice in notices {
                        let wings = notice.wings(in: geometry)
                        func content(_ wing: CGFloat) -> CGFloat { wing - notice.inset(wing: wing) - notice.cameraGap }
                        suite.expect(width(notice.title) + 18 + 8 <= content(wings.leading),
                               "power labels and a layout's code fit beside their icon in \(language)")
                        suite.expect(width(notice.detail) <= content(wings.trailing),
                               "a layout's name and a charge percentage fit the opposite wing in \(language)")
                        let size = geometry.noticeSize(wings: wings)
                        var shifted = geometry
                        shifted.surfaceShift = geometry.noticeShift(wings)
                        let frame = shifted.frame(for: size)
                        suite.expect(size.width == wings.leading + wings.trailing + geometry.cameraWidth && size.height == height
                               && screen.contains(frame)
                               && abs(frame.minX + wings.leading - (screen.midX - geometry.cameraWidth / 2)) < 0.001,
                               "content-sized notices keep the camera's gap over it, the menu height and the display bounds")
                    }
                }
            }
        }
        let long = NotchNotice(event: .inputSource, title: "ABC",
                               detail: String(repeating: "Layout ", count: 100), symbol: "keyboard")
        suite.expect(long.preferredWings.trailing == 240 && long.accessibilityText.contains(long.detail),
               "a very long layout name has a bounded visual width and keeps its full accessible name")
        let narrow = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 640, height: 480),
                                   safeAreaTop: 32, cameraWidth: 210)
        let size = narrow.noticeSize(wings: long.preferredWings)
        suite.expect(size.width <= narrow.screen.width - 24 && size.height == narrow.menuBarHeight,
               "long names cannot push a notice past a narrow display")
    }

    private static func simulatedMenuBoundsContracts(_ suite: TestSuite) {
        let screen = CGRect(x: -1470, y: 100, width: 1470, height: 956)
        for height: CGFloat in [16, 22, 24, 32, 40, 64] {
            let bar = CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
            for room: CGFloat? in [nil, 0, 12, 43, 44, 56, 64] {
                let geometry = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0,
                                             menuBarHeight: height, compactSideRoom: room)
                let sizes = [geometry.restingSize(showsContent: false), geometry.collapsed,
                             geometry.notice, geometry.noticeSize(wingWidth: 190),
                             geometry.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.upperBound).compactActivitySize,
                             geometry.compactKeepAwakeGeometry().compactActivitySize,
                             geometry.compactActivitySize]
                for size in sizes {
                    suite.expect(bar.contains(geometry.frame(for: size)),
                           "every closed or compact simulated surface stays entirely within the actual menu bar")
                }
                suite.expect(abs(geometry.cameraWidth / geometry.cameraHeight - 180.0 / 32) < 0.001,
                       "fitting a shorter menu bar scales the whole simulated camera profile proportionally")
            }
            var crowded = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: height)
            let camera = crowded.frame(for: crowded.restingSize(showsContent: false))
            let occupied = [CGRect(x: screen.minX, y: bar.minY, width: camera.minX - screen.minX - 10, height: height),
                            CGRect(x: camera.maxX + 10, y: bar.minY, width: screen.maxX - camera.maxX - 10, height: height)]
            crowded.compactSideRoom = NotchMenuBarLayout.sideRoom(screen: screen, cameraWidth: crowded.cameraWidth,
                                                                 barHeight: height, occupied: occupied)
            for size in [crowded.collapsed,
                         crowded.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.upperBound).compactActivitySize,
                         crowded.compactKeepAwakeGeometry().compactActivitySize] {
                suite.expect(!occupied.contains(where: { $0.intersects(crowded.frame(for: size)) }),
                       "simulated idle, agent and Keep Awake wings never cover measured neighboring menus")
            }
        }
    }

    private static func simulatedDisplayContracts(_ suite: TestSuite) {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                       CGRect(x: 100, y: 982, width: 900, height: 1440),
                       CGRect(x: 0, y: 0, width: 640, height: 480)]
        let rooms: [CGFloat?] = [nil, 0, 43, 64, 200, .nan, .infinity]
        for screen in screens {
            for barHeight: CGFloat in [16, 24, 32, 40, 64] {
                let physical = NotchGeometry(screen: screen, safeAreaTop: barHeight, cameraWidth: 180 * barHeight / 32,
                                             menuBarHeight: barHeight)
                for room in rooms {
                    let geometry = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0,
                                                 menuBarHeight: barHeight, compactSideRoom: room)
                    suite.expect(!geometry.isNotched && geometry.cameraWidth == physical.cameraWidth
                           && geometry.cameraHeight == physical.cameraHeight
                           && geometry.safeContentTop == physical.safeContentTop,
                           "a simulated notch keeps the physical profile and content clearance without claiming hardware exists")
                    suite.expect(geometry.restingSize(showsContent: false) == physical.restingSize(showsContent: false)
                           && geometry.notice == physical.notice && geometry.expanded.width == physical.expanded.width
                           && geometry.contentSize(for: geometry.expanded) == physical.contentSize(for: physical.expanded),
                           "simulated and physical cutouts share compact proportions and the same usable page budget")
                    let sizes = [geometry.restingSize(showsContent: false), geometry.collapsed, geometry.peek,
                                 geometry.notice, geometry.noticeSize(wingWidth: 190)]
                        + NotchModule.allCases.map { geometry.expandedSize(module: $0) }
                        + [geometry.sectionPickerSize(count: NotchModule.allCases.count)]
                    for size in sizes {
                        let positioned = geometry.frame(for: size)
                        suite.expect(screen.contains(positioned) && positioned.midX == screen.midX
                               && positioned.maxY == screen.maxY,
                               "every simulated presentation grows directly from the screen edge and stays within its display")
                    }
                    for activity in [geometry, geometry.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.upperBound),
                                     geometry.compactKeepAwakeGeometry()] {
                        let positioned = activity.frame(for: activity.compactActivitySize)
                        let activation = activity.activationArea(in: activity.compactActivitySize, hasHeader: false,
                                                                 compactActivity: true)
                        suite.expect(positioned.maxY == screen.maxY && screen.contains(positioned)
                               && (activity.compactActivityWingWidth == 0 || activity.compactActivityWingWidth >= 44)
                               && activity.compactActivityContentHeight == barHeight,
                               "simulated activities keep complete measured wings or just the cutout, within the menu bar")
                        suite.expect(activity.compactActivityCameraGap == physical.cameraWidth && !activity.compactActivityUsesFooter
                               && activation.width == physical.cameraWidth
                               && activation.midX == activity.compactActivitySize.width / 2,
                               "the simulated camera opens the island while its neighboring controls keep their own click targets")
                    }
                }
            }
        }
    }

    private static func menuSpaceReuseContracts(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let previous = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 24, compactSideRoom: 0)
        let largerBar = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 32)
        let menu = CGRect(x: screen.midX + previous.cameraWidth / 2 + 4, y: screen.maxY - 24, width: 80, height: 24)
        suite.expect(NotchMenuBarLayout.sideRoom(screen: screen, cameraWidth: previous.cameraWidth, barHeight: 24, occupied: [menu]) != nil
               && NotchMenuBarLayout.sideRoom(screen: screen, cameraWidth: largerBar.cameraWidth, barHeight: 32, occupied: [menu]) == nil,
               "a taller simulated cutout can occupy a menu that was clear before the bar changed")
        suite.expect(!largerBar.hasSameMenuBar(as: previous),
               "a changed menu bar cannot reuse clearance from a narrower simulated camera")
        let moved = NotchGeometry(screen: screen.offsetBy(dx: -1440, dy: 900), safeAreaTop: 0, cameraWidth: 0)
        suite.expect(!moved.hasSameMenuBar(as: previous), "another display cannot reuse the previous menu measurement")
        for layout in NotchSize.allCases {
            let resized = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, layout: layout)
            suite.expect(resized.hasSameMenuBar(as: previous),
                   "changing the expanded size preserves valid menu clearance without flicker")
        }
    }

    private static func menuBarHeightContracts(_ suite: TestSuite) {
        var measurements = NotchMenuBarMeasurements()
        let screen = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        func read(_ id: UInt32, gap: CGFloat, frame: CGRect = CGRect(x: -1440, y: -900, width: 1440, height: 900),
                  scale: CGFloat = 2, fallback: CGFloat = 22) -> CGFloat {
            measurements.height(displayID: id, frame: frame, visibleTop: frame.maxY - gap,
                                scale: scale, statusBarThickness: fallback)
        }
        for gap: CGFloat in [16, 24, 37, 64] {
            suite.expect(NotchMenuBarMeasurements.showsBar(frame: screen, visibleTop: screen.maxY - gap),
                   "a bar reserving its height at the top of the visible frame is on screen")
        }
        for gap: CGFloat in [0, 1, -10, 15, 65, 600, .nan, .infinity] {
            suite.expect(!NotchMenuBarMeasurements.showsBar(frame: screen, visibleTop: screen.maxY - gap),
                   "a bar that hides until revealed, or a display without one, reserves no room")
        }
        for height: CGFloat in [16, 22, 24, 28, 30, 32, 33, 37, 64] {
            suite.expect(read(1, gap: height) == height, "the selected display's current visible bar supplies its height")
            let geometry = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: height)
            suite.expect(geometry.collapsed.height == height && geometry.compactKeepAwakeGeometry().compactActivitySize.height == height,
                   "the simulated cutout and an activity's strip stay within the measured bar")
            for gap: CGFloat in [0, 1, -10, 15, 65, 600, .nan, .infinity] {
                suite.expect(read(1, gap: gap) == height, "hiding or an unavailable reading retains this display's measured height")
            }
        }
        suite.expect(read(1, gap: 24) == 24 && read(2, gap: 33) == 33,
               "displays with different menu bars keep independent measurements")
        for _ in 0..<3 {
            suite.expect(read(1, gap: 0) == 24 && read(2, gap: 0) == 33,
                   "switching displays and changing other preferences while bars are hidden preserves both heights")
        }
        suite.expect(read(3, gap: 0) == 22 && read(3, gap: 0, fallback: .nan) == 24,
               "a display first seen with a hidden bar uses a safe native fallback, never another display's height")
        suite.expect(read(3, gap: 30) == 30 && read(3, gap: 0) == 30,
               "revealing a previously unknown bar replaces the fallback and survives hiding again")
        suite.expect(read(1, gap: 0, frame: screen.offsetBy(dx: 1440, dy: 1800)) == 24,
               "moving a display in the arrangement preserves its mode's measured height")
        suite.expect(read(1, gap: 0, scale: 1) == 22 && read(1, gap: 0, scale: 2) == 22,
               "a scale change invalidates the old height even after changing back while the bar stays hidden")
        _ = read(1, gap: 30)
        suite.expect(read(1, gap: 0, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) == 22,
               "a new screen resolution cannot inherit a previous mode's height")
        measurements.retainDisplays([1, 3])
        suite.expect(read(2, gap: 0) == 22 && read(3, gap: 0) == 30,
               "disconnecting a display drops its history without affecting the remaining display")
        suite.expect(read(0, gap: 37) == 37 && read(0, gap: 0) == 22,
               "an unknown display identity can use its current reading but cannot share remembered measurements")
        _ = read(1, gap: 30, scale: .nan)
        suite.expect(read(1, gap: 0) == 22, "an invalid display mode cannot seed remembered height")
        var fresh = NotchMenuBarMeasurements()
        for invalid: CGFloat in [0, -1, 15, 65, .nan, .infinity] {
            suite.expect(fresh.height(displayID: 1, frame: screen, visibleTop: screen.maxY,
                                scale: 2, statusBarThickness: invalid) == 24,
                   "invalid fallback heights never escape the safe range")
        }
    }

    /// By default the island is the housing macOS reports; covering the menu bar below it is opt-in.
    private static func physicalStripContracts(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        for safeTop: CGFloat in [24, 32, 37.5, 40] {
            for barHeight: CGFloat in [24, 32, 33, 37, 38, 39, 40, 64] {
                let geometry = NotchGeometry(screen: screen, safeAreaTop: safeTop, cameraWidth: 179,
                                             menuBarHeight: barHeight, compactSideRoom: 100)
                let strips = [geometry.restingSize(showsContent: false), geometry.restingSize(showsContent: true),
                              geometry.collapsed, geometry.bareCutout, geometry.notice,
                              geometry.noticeSize(wingWidth: 190),
                              geometry.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.upperBound).compactActivitySize,
                              geometry.compactKeepAwakeGeometry().compactActivitySize]
                for size in strips {
                    suite.expect(size.height == safeTop && size.height == geometry.stripHeight,
                           "every physical strip is exactly as tall as the cutout, so it never reaches below the notch")
                }
                suite.expect(geometry.menuBarHeight == max(safeTop, barHeight),
                       "the bar's own height remains available for measuring menu space")
                let covering = NotchGeometry(screen: screen, safeAreaTop: safeTop, cameraWidth: 179,
                                             menuBarHeight: barHeight, compactSideRoom: 100, hideMenuBarGap: true)
                let covered = [covering.restingSize(showsContent: false), covering.restingSize(showsContent: true),
                               covering.collapsed, covering.bareCutout, covering.notice,
                               covering.noticeSize(wingWidth: 190),
                               covering.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.upperBound).compactActivitySize,
                               covering.compactKeepAwakeGeometry().compactActivitySize]
                for size in covered {
                    suite.expect(size.height == max(safeTop, barHeight) && size.height == covering.stripHeight
                           && covering.frame(for: size).minY <= screen.maxY - barHeight,
                           "hiding the gap covers the bar's bottom edge without leaving a wallpaper seam")
                }
            }
        }
        for silhouette in NotchSilhouette.allCases {
            let enabled = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0,
                                        silhouette: silhouette, hideMenuBarGap: true)
            let disabled = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0,
                                         silhouette: silhouette, hideMenuBarGap: false)
            suite.expect(enabled == disabled, "gap hiding leaves simulated notches and floating capsules unchanged")
        }
        let closed = NotchLayout.surfaceRadius(height: 32)
        suite.expect(closed >= 8 && closed <= 12 && NotchLayout.shoulder(height: 32) >= 5 && NotchLayout.shoulder(height: 32) <= 8,
               "a closed island keeps corners like the cutout's, so a collapse settles inside the notch")
        suite.expect(NotchLayout.surfaceRadius(height: 286) == 28 && NotchLayout.shoulder(height: 286) == NotchLayout.shoulder,
               "an open island keeps its full corner radius and shoulder")
    }

    /// macOS rounds the camera housing it reports, so an edge of the real
    /// notch can show past the island. A fit set by hand moves whatever
    /// follows the cutout and nothing else, and stays on the Mac it was set on.
    private static func cameraFitContracts(_ suite: TestSuite) {
        let handWritten = NotchCameraFit(width: 2.4, height: 0.3)
        let negative = NotchCameraFit(width: -2.6, height: -1.3)
        suite.expect(handWritten.width == 2 && handWritten.height == 0.5
                     && negative.width == -3 && negative.height == -1.5
                     && NotchCameraFit(width: 40, height: -9).width == 10 && NotchCameraFit(width: 40, height: -9).height == -6,
                     "a notch fit written by hand is brought back to whole-point widths and half-point heights within range")
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let reported = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 179,
                                     menuBarHeight: 33, compactSideRoom: 100)
        let fitted = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 179,
                                   menuBarHeight: 33, compactSideRoom: 100,
                                   cameraFit: NotchCameraFit(width: 2, height: 0.5))
        suite.expect(reported.cameraWidth == 179 && reported.cameraHeight == 32,
               "without a fit the island matches the housing macOS reports")
        suite.expect(fitted.cameraWidth == 181 && fitted.cameraHeight == 32.5,
               "a fit widens and lengthens the camera housing the island covers")
        let strips = [fitted.restingSize(showsContent: false), fitted.restingSize(showsContent: true), fitted.collapsed,
                      fitted.notice, fitted.noticeSize(wingWidth: 190),
                      fitted.compactAgentGeometry(wing: NotchAgentSupport.stripWingRange.upperBound).compactActivitySize,
                      fitted.compactKeepAwakeGeometry().compactActivitySize]
        suite.expect(strips.allSatisfy { $0.height == 32.5 && $0.height == fitted.stripHeight },
               "every strip beside the camera, notices included, follows the fitted height")
        suite.expect(fitted.restingSize(showsContent: false).width == 181
               && fitted.noticeCameraGap == 181 && fitted.compactKeepAwakeGeometry().compactActivityCameraGap == 181,
               "the closed island and the gap between wings follow the fitted width")
        suite.expect(fitted.notice.width == reported.notice.width + 2
               && fitted.noticeWingWidth(preferred: 80) == reported.noticeWingWidth(preferred: 80),
               "a notice keeps its wings beside a wider camera")
        suite.expect(fitted.expandedWidth == reported.expandedWidth && fitted.contentBudget == reported.contentBudget,
               "the open island keeps its chosen size")
        let shorter = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 179,
                                    cameraFit: NotchCameraFit(width: -3, height: -1))
        suite.expect(shorter.cameraWidth == 176 && shorter.notice.height == 31,
               "a housing reported too large can be narrowed and shortened")

        let plain = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 24)
        let simulated = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 24,
                                      cameraFit: NotchCameraFit(width: 10, height: 6))
        suite.expect(simulated == plain, "a display without a camera keeps its simulated cutout")

        let extreme = NotchCameraFit(width: 100, height: -100)
        suite.expect(extreme.width == 10 && extreme.height == -6, "a fit stays within its ranges")
        suite.expect(NotchCameraFit(width: .nan, height: .infinity) == .zero, "an unreadable fit means none")

        let domain = "brim.tests.notch-camera-fit"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchCameraFitWidth] as? Double == 0
               && Defaults.registeredDefaults[DefaultsKey.notchCameraFitHeight] as? Double == 0
               && NotchCameraFit.current(in: defaults) == .zero,
               "the island follows the reported housing until someone fits it")
        defaults.set(-3.0, forKey: DefaultsKey.notchCameraFitWidth)
        defaults.set(1.5, forKey: DefaultsKey.notchCameraFitHeight)
        suite.expect(NotchCameraFit.current(in: defaults) == NotchCameraFit(width: -3, height: 1.5),
               "the stored fit is read back as set")
    }

    /// The outline is drawn inside the island's edge, so an island that only
    /// covers a physical camera hides its line behind the housing.
    private static func outlineRoomContracts(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let room = NotchLayout.outlineWidth
        let bare = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 179,
                                 menuBarHeight: 33, compactSideRoom: 100)
        let outlined = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 179,
                                     menuBarHeight: 33, compactSideRoom: 100, outline: true)
        suite.expect(bare.outlineRoom == 0 && outlined.outlineRoom == room
               && outlined.restingSize(showsContent: false) == CGSize(width: 179 + room * 2, height: 32 + room),
               "an outlined island reaches past the camera by the line's width, so the line shows around the notch")
        suite.expect([outlined.restingSize(showsContent: true), outlined.notice,
                      outlined.compactKeepAwakeGeometry().compactActivitySize].allSatisfy { $0.height == 32 + room },
               "every strip beside the camera keeps its line clear of the housing")
        suite.expect(!outlined.hasSameMenuBar(as: bare), "turning the outline on measures the menus again for the wider island")
        suite.expect(outlined.bareCutout == bare.restingSize(showsContent: false)
               && bare.bareCutout == bare.restingSize(showsContent: false),
               "full screen and the Lock Screen draw no outline, so their cutout keeps to the camera")
        let fitted = NotchGeometry(screen: screen, safeAreaTop: 32, cameraWidth: 179,
                                   cameraFit: NotchCameraFit(width: -3, height: -1), outline: true)
        suite.expect(fitted.cameraWidth == 176 + room * 2 && fitted.cameraHeight == 31 + room,
               "the outline's room adds to a notch fit")
        for silhouette in [NotchSilhouette.notch, .capsule] {
            let plain = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 24, silhouette: silhouette)
            let simulated = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 24,
                                          silhouette: silhouette, outline: true)
            suite.expect(simulated == plain, "a cutout without a camera already shows its outline on the menu bar")
        }
    }

    private static func activitySelectionContracts(_ suite: TestSuite) {
        for mask in 0..<4 {
            let available = NotchSupport.compactActivities(agents: mask & 1 != 0, keepAwake: mask & 2 != 0)
            var selection = NotchActivitySelection()
            suite.expect(selection.current(available: available) == available.first,
                         "available activities keep automatic priority until a choice is made")
            for activity in available {
                selection.select(activity, available: available)
                selection.reconcile(available: available)
                suite.expect(selection.current(available: available) == activity,
                             "every live activity can remain selected through refreshes")
                let remaining = available.filter { $0 != activity }
                selection.reconcile(available: remaining)
                suite.expect(selection.current(available: remaining) == remaining.first,
                             "while the chosen activity pauses, the island shows the next one")
                if !remaining.isEmpty {
                    suite.expect(selection.current(available: available) == activity,
                                 "an agent between turns keeps the choice")
                } else {
                    suite.expect(selection.preferred == nil,
                                 "the choice ends once the island has nothing left to show")
                }
                selection.reconcile(available: [])
                suite.expect(selection.current(available: available) == available.first,
                             "activities returning to an empty island start from the automatic order")
            }
        }
        suite.expect(NotchSupport.compactActivities(agents: true, keepAwake: true) == [.agents, .keepAwake],
                     "Keep Awake comes after a working agent: a session can run all day")
        var selection = NotchActivitySelection()
        selection.select(.keepAwake, available: [.agents, .keepAwake])
        selection.reconcile(available: [.agents, .keepAwake])
        suite.expect(selection.current(available: [.agents, .keepAwake]) == .keepAwake,
                     "an agent starting does not steal an explicit choice")
        selection.select(.agents, available: [.keepAwake])
        suite.expect(selection.preferred == .keepAwake, "a late click on a removed choice is ignored")
        for height: CGFloat in [16, 22, 32, 40, 64] {
            for width: CGFloat in [200, 320, 560] {
                let strip = CGSize(width: width, height: height)
                let layout = NotchActivityPickerLayout(count: 2, labelWidth: 60, stripSize: strip, screenWidth: 1024)
                let shape = NotchShape(attached: true, radius: NotchLayout.surfaceRadius(height: layout.size.height))
                    .path(in: CGRect(origin: .zero, size: layout.size))
                let inset = (layout.size.width - width) / 2
                for x in [inset, inset + width] {
                    for y in [CGFloat(1), height - 1] {
                        suite.expect(shape.contains(CGPoint(x: x, y: y)),
                                     "the full strip, including its edge marks and readings, fits inside the picker silhouette")
                    }
                }
            }
        }
        for language in AppLanguage.allCases {
            let activities: [NotchCompactActivity] = [.agents, .keepAwake]
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let width = activities.map {
                ($0.title(language) as NSString).size(withAttributes: [.font: font]).width
            }.max()!
            let layout = NotchActivityPickerLayout(count: activities.count, labelWidth: width,
                stripSize: CGSize(width: 300, height: 32), screenWidth: 1024)
            let cell = (layout.size.width - NotchActivityPickerLayout.horizontalInset * 2
                        - CGFloat(layout.columns - 1) * 6) / CGFloat(layout.columns)
            suite.expect(cell >= width + 48 && layout.size.width <= 1000
                         && layout.headerHeight == 32,
                         "named activity buttons fit without truncation below the camera in \(language.rawValue)")
        }
    }

    private static func shortcutContracts(_ suite: TestSuite) {
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchShortcutEnabled] as? Bool == false,
               "the island shortcut ships off, so no key is taken until the user asks")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchShortcut] as? String
                == "control+option+command:34",
               "the default island shortcut is control option command I")
        suite.expect(!GlobalShortcutRole.allCases.contains { $0 != .notch && $0.defaultShortcut == .notchDefault },
               "the default island shortcut is not another feature's default")
        func active(_ keys: Set<String>) -> Bool {
            GlobalShortcutRole.activeRoles(isOn: { keys.contains($0) }).contains(.notch)
        }
        suite.expect(active([DefaultsKey.notchEnabled, DefaultsKey.notchShortcutEnabled])
                && !active([DefaultsKey.notchShortcutEnabled])
                && !active([DefaultsKey.notchEnabled]),
               "the island shortcut is live only while both the island and its shortcut are on")
        suite.expect(!GlobalShortcutRole.activeRoles(isOn: { _ in true },
                                                     isAvailable: { $0 != .notch }).contains(.notch),
               "an island removed in the hub does not reserve its shortcut")
        let domain = "brim.tests.notch-shortcut-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        func holds(installed: Bool = true, island: Bool = true, shortcut: Bool = true) -> Bool {
            defaults.set(installed, forKey: AppFeature.notch.availabilityKey)
            defaults.set(island, forKey: DefaultsKey.notchEnabled)
            defaults.set(shortcut, forKey: DefaultsKey.notchShortcutEnabled)
            return NotchSupport.holdsShortcut(in: defaults)
        }
        suite.expect(holds(), "the island shortcut holds its key while the island and its shortcut are on")
        suite.expect(!holds(island: false), "the island shortcut is not wanted while the island is off")
        suite.expect(!holds(installed: false), "the island shortcut is not wanted while the island is removed in the hub")
        suite.expect(!holds(shortcut: false), "turning the island shortcut off releases its key")
        // The service is a singleton holding a real Carbon hotkey, so its
        // wiring is checked in the source, like the launch hooks below.
        let service = (try? String(contentsOfFile: "Sources/Brim/Services/Notch/NotchService.swift",
                                   encoding: .utf8)) ?? ""
        suite.expect(service.contains("hotkey.onPress = { [weak self] in self?.toggleFromShortcut() }"),
               "the island shortcut answers like a click on the island")
        suite.expect(service.contains("guard NotchSupport.isEnabled() else { stop(); return }")
                && service.contains("        syncShortcut()\n        // Paused while"),
               "every preference sync of a running island registers or releases its shortcut")
        suite.expect(service.contains("preferenceSyncWork?.cancel(); preferenceSyncWork = nil\n        hotkey.unregister()"),
               "stopping the island releases its shortcut")
    }

    static func run(_ suite: TestSuite) {
        shortcutContracts(suite)
        let previewStrip: CGFloat = 37
        suite.expect(NotchTranslucentTint.opacity(atDepth: previewStrip, stripHeight: previewStrip,
                                                  openness: 1, increasedContrast: false) == 1
                && NotchTranslucentTint.opacity(atDepth: 0, stripHeight: previewStrip,
                                                openness: 1, increasedContrast: false) == 1,
               "the translucent background stays black down to the camera strip in the hover preview")
        suite.expect(abs(NotchTranslucentTint.opacity(atDepth: previewStrip + 62, stripHeight: previewStrip,
                                                      openness: 1, increasedContrast: false) - 0.38) < 0.001
                && NotchTranslucentTint.opacity(atDepth: previewStrip + 62, stripHeight: previewStrip,
                                                openness: 1, increasedContrast: true) > 0.69,
               "below the strip the translucent body opens, less with Increase Contrast")
        func stripIsBlack(islandHeight: CGFloat) -> Bool {
            let stops = NotchTranslucentTint.stops(height: islandHeight, stripHeight: previewStrip,
                                                   openness: 1, increasedContrast: false)
            let stripEnd = Double(previewStrip / islandHeight)
            return stops.filter { $0.location <= stripEnd + 1e-9 }.allSatisfy { $0.opacity == 1 }
                && stops.contains { abs($0.location - stripEnd) < 1e-9 }
        }
        suite.expect(stripIsBlack(islandHeight: previewStrip + 62) && stripIsBlack(islandHeight: 400),
               "the strip stays black at every island height, tall or at the preview's")

        NotchMissionControlPollingTests.run(suite)
        activitySelectionContracts(suite)
        railContracts(suite)
        presentationSpacingContracts(suite)
        pageTopContracts(suite)
        pageWidthContracts(suite)
        sectionsButtonContracts(suite)
        homeRailContracts(suite)
        noticeLayoutContracts(suite)
        simulatedMenuBoundsContracts(suite)
        simulatedDisplayContracts(suite)
        menuSpaceReuseContracts(suite)
        menuBarHeightContracts(suite)
        physicalStripContracts(suite)
        cameraFitContracts(suite)
        outlineRoomContracts(suite)
        NotchPanelTests.run { suite.expect($0, $1) }
        NotchHoverTests.run(suite)
        NotchScreenEdgeClickTests.run(suite)
        NotchClickElsewhereTests.run(suite)
        NotchPresentationRefreshContract.run(suite)
        NotchScreenRefreshContract.run(suite)
        NotchMirrorContract.run(suite)
        NotchFullscreenTests.run(suite)
        NotchVisibilityTests.run(suite)
        NotchDestinationContract.run(suite)
        WindowVisibilityTests.run { suite.expect($0, $1) }
        NotchKeyMonitorTests.run(suite)
        NotchSectionPagingTests.run(suite)
        NotchActivityTests.run(suite)
        NotchLockScreenTests.run(suite)
        NotchClipboardPageTests.run(suite)
        for language in AppLanguage.allCases {
            let strings = Mirror(reflecting: FeatureStrings.notchClipboardSize(language)).children.compactMap { $0.value as? String }
            suite.expect(strings.count == 4 && strings.allSatisfy { !$0.isEmpty && !$0.contains("—") },
                         "the clipboard entry size has complete strings in \(language.rawValue)")
        }
        let sizeDomain = "brim.tests.notch-clipboard-size"
        let sizeDefaults = UserDefaults(suiteName: sizeDomain)!
        sizeDefaults.removePersistentDomain(forName: sizeDomain)
        defer { sizeDefaults.removePersistentDomain(forName: sizeDomain) }
        // Existing users keep the entries they had until they choose compact ones.
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchClipboardCardSize] as? String
                        == NotchClipboardCardSize.comfortable.rawValue,
                     "clipboard entries are registered comfortable, the size they had before compact ones")
        suite.expect(NotchClipboardCardSize.current(in: sizeDefaults) == .comfortable
                     && NotchClipboardCardSize(stored: nil) == .comfortable,
                     "clipboard entries start comfortable with nothing stored")
        sizeDefaults.set("compact", forKey: DefaultsKey.notchClipboardCardSize)
        suite.expect(NotchClipboardCardSize.current(in: sizeDefaults) == .compact
                     && NotchClipboardCardSize(stored: "compact") == .compact, "the chosen entry size is read")
        sizeDefaults.set("huge", forKey: DefaultsKey.notchClipboardCardSize)
        suite.expect(NotchClipboardCardSize.current(in: sizeDefaults) == .comfortable
                     && NotchClipboardCardSize(stored: "huge") == .comfortable,
                     "an unknown entry size falls back to comfortable")
        typealias Size = NotchClipboardCardSize
        suite.expect(Size.openLines(for: "one line", width: 400) == 1
                     && Size.openLines(for: "a\nb\nc", width: 400) == 3
                     && Size.openLines(for: String(repeating: "x", count: 130), width: 400) == 3
                     && Size.openLines(for: String(repeating: "word ", count: 1000), width: 400) == Size.maximumOpenLines
                     && Size.openLines(for: "", width: 400) == 1,
                     "an open entry shows its lines, counting wrapped ones, up to a limit")
        // A Chinese, Japanese or Korean character is about twice as wide as a
        // Latin letter: 100 of them wrap to four lines in 400 points.
        suite.expect(Size.openLines(for: String(repeating: "漢", count: 100), width: 400) == 4
                     && Size.openLines(for: String(repeating: "日本語のテキスト", count: 10), width: 400) == 3,
                     "an open entry measures wide characters as drawn, not as Latin letters")
        // The history window edits an entry's text and keeps its id.
        let measured = UUID()
        suite.expect(Size.openHeight(text: "short", width: 400, id: measured) == Size.openLineHeight + Size.openChrome
                     && Size.openHeight(text: String(repeating: "x\n", count: 50), width: 400, id: measured)
                        == CGFloat(Size.maximumOpenLines) * Size.openLineHeight + Size.openChrome
                     && Size.openHeight(text: "short", width: 400, id: measured) == Size.openLineHeight + Size.openChrome
                     && Size.openHeight(text: String(repeating: "漢", count: 100), width: 100, id: measured)
                        == CGFloat(Size.maximumOpenLines) * Size.openLineHeight + Size.openChrome,
                     "an open clipboard entry measures its text again once edited, and at each width")
        suite.expect(Size.openHeight(text: "short", width: 400) == Size.openLineHeight + Size.openChrome
                     && Size.openHeight(text: String(repeating: "x\n", count: 50), width: 400)
                        == CGFloat(Size.maximumOpenLines) * Size.openLineHeight + Size.openChrome,
                     "an open text entry is as tall as its lines, up to a limit")
        suite.expect(Size.openHeight(aspectRatio: 1.6, width: 400) == Size.maximumOpenImage + Size.openChrome,
                     "a wide image opens at the tallest it may")
        suite.expect(Size.openHeight(aspectRatio: 20, width: 400) == Size.minimumOpenImage + Size.openChrome
                     && Size.openHeight(aspectRatio: 1, width: 100) == 100 + Size.openChrome
                     && Size.openHeight(aspectRatio: nil, width: 300) == Size.maximumOpenImage + Size.openChrome,
                     "an open image keeps its proportions within a range, and one with none is taken as wide")
        suite.expect(NotchLayout.clipboardCompactCardHeight < NotchLayout.clipboardCardHeight && NotchClipboardCardSize.dwell > 0,
                     "a compact entry is shorter than an open one and opens after a pause")
        let domain = "brim.tests.notch"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        // Registration defaults are shared across suites within the process.
        // Keep this fixture inside its own persistent domain so migration
        // tests later in the harness still see a genuinely untouched setup.
        for (key, value) in Defaults.registeredDefaults
        where key.hasPrefix("notch") || key == DefaultsKey.clipboardHistoryEnabled {
            defaults.set(value, forKey: key)
        }
        for (key, value) in AppFeature.availabilityDefaults { defaults.set(value, forKey: key) }
        let firstDefaults = Defaults.registeredDefaults
        suite.expect(firstDefaults[DefaultsKey.notchSize] as? String == NotchSize.spacious.rawValue
                     && firstDefaults[DefaultsKey.notchOpenOnHover] as? Bool == false
                     && firstDefaults[DefaultsKey.notchAppPanel] as? Bool == false,
                     "a first island setup starts spacious, opens by click and uses a separate app panel")
        suite.expect(firstDefaults[DefaultsKey.notchHapticFeedback] as? Bool == true
                     && firstDefaults[DefaultsKey.notchReturnHome] as? Bool == false
                     && firstDefaults[DefaultsKey.notchCoversMenus] as? Bool == true,
                     "haptics, last page and coverage over menus start selected")
        let enabledByDefault = [DefaultsKey.notchClipboard, DefaultsKey.notchBattery, DefaultsKey.notchInputSource]
        suite.expect(enabledByDefault.allSatisfy { firstDefaults[$0] as? Bool == true },
                     "the island's activity indicators start enabled")
        suite.expect(firstDefaults[DefaultsKey.notchAgentsEnabled] as? Bool == false,
                     "new island setups leave local agent history reading off until chosen")

        suite.expect(!NotchSupport.isEnabled(in: defaults), "notch is opt-in")
        suite.expect(NotchSupport.controls(in: defaults) == [.keepAwake],
               "home defaults show Keep Awake; the speed test and the app panel wait to be chosen")
        defaults.set("", forKey: DefaultsKey.notchHiddenControls)
        suite.expect(NotchSupport.controls(in: defaults) == [.keepAwake, .speedTest, .panel],
               "every home control can be shown")
        defaults.set("system", forKey: DefaultsKey.notchHiddenModules)
        suite.expect(!NotchSupport.controls(in: defaults).contains(.speedTest),
               "home controls respect hidden destinations")
        defaults.set("", forKey: DefaultsKey.notchHiddenModules)
        defaults.set(NotchControlItem.defaultHidden, forKey: DefaultsKey.notchHiddenControls)
        // A capsule's row runs across the island; the 13-inch camera at the
        // compact width and the spacious one both wrap the camera.
        let capsuleHome = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                                        cameraWidth: 0, menuBarHeight: 24, silhouette: .capsule)
        let narrowHome = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1470, height: 956), safeAreaTop: 32, cameraWidth: 180)
        let wideHome = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1280, height: 832), safeAreaTop: 28,
                                     cameraWidth: 156, layout: .spacious, menuBarHeight: 28)
        suite.expect([capsuleHome, narrowHome, wideHome].allSatisfy { geometry in
                   geometry.contentSize(for: geometry.expandedSize(module: .controls, shortcutCount: 3)).height
                       == NotchLayout.controls(shortcutCount: 3, width: geometry.contentWidth,
                                               height: geometry.contentBudget).height
               },
               "the home page is as tall as its rail of shortcuts")

        suite.expect(NotchSupport.showsInCaptures(in: defaults), "notch appears in screenshots and recordings by default")
        suite.expect(NotchSupport.showsInCaptures(in: defaults), "the old inverse default cannot silently hide the notch")
        defaults.set(false, forKey: DefaultsKey.notchShowInCaptures)
        suite.expect(!NotchSupport.showsInCaptures(in: defaults), "capture visibility remains an explicit opt-out")
        defaults.set(true, forKey: DefaultsKey.notchShowInCaptures)
        suite.expect(!NotchSupport.hidesUntilHover(in: defaults), "the closed island stays in sight by default")
        defaults.set(true, forKey: DefaultsKey.notchHideUntilHover)
        suite.expect(!NotchSupport.hidesUntilHover(in: defaults), "click to open does not hide the island until hover")
        defaults.set(true, forKey: DefaultsKey.notchOpenOnHover)
        suite.expect(NotchSupport.hidesUntilHover(in: defaults), "hidden until hover waits out of sight for the pointer")
        defaults.set(true, forKey: DefaultsKey.notchHiddenShowsActivity)
        defaults.set(false, forKey: DefaultsKey.notchOpenOnHover)
        suite.expect(!NotchSupport.hiddenShowsActivity(in: defaults), "showing activity only applies while hidden until hover")
        defaults.set(true, forKey: DefaultsKey.notchOpenOnHover)
        defaults.set(false, forKey: DefaultsKey.notchHiddenShowsActivity)
        defaults.set(false, forKey: DefaultsKey.notchOpenOnHover)
        suite.expect(!NotchSupport.hidesUntilHover(in: defaults), "an island that opens by click never waits for hover")
        defaults.set(false, forKey: DefaultsKey.notchHideUntilHover)
        suite.expect(NotchEvent.allCases.allSatisfy { !NotchSupport.routes($0, in: defaults) },
               "disabled notch cannot consume any existing presentation")
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        suite.expect(NotchSupport.isEnabled(in: defaults), "master switch enables notch")
        suite.expect(NotchSupport.usesHapticFeedback(in: defaults), "the enabled island starts with tactile feedback")
        defaults.set(false, forKey: DefaultsKey.notchHapticFeedback)
        suite.expect(!NotchSupport.usesHapticFeedback(in: defaults), "tactile feedback can still be turned off independently")
        defaults.set(true, forKey: DefaultsKey.notchHapticFeedback)
        defaults.set(false, forKey: DefaultsKey.notchEnabled)
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        suite.expect(NotchSupport.usesHapticFeedback(in: defaults), "disabling the notch preserves the user's tactile preference")
        suite.expect(NotchSupport.idleContent(in: defaults) == .none, "a new island rests empty")
        suite.expect(defaults.string(forKey: DefaultsKey.notchSize) == NotchSize.spacious.rawValue
               && !defaults.bool(forKey: DefaultsKey.notchOpenOnHover),
               "a new island starts spacious and opens by click")
        suite.expect(!defaults.bool(forKey: DefaultsKey.notchHideUntilHover), "hidden hover is opt-in")
        suite.expect(!defaults.bool(forKey: DefaultsKey.notchOutlineEnabled), "the island outline is opt-in")
        suite.expect(!defaults.bool(forKey: DefaultsKey.notchHideMenuBarGap),
                     "the island matches the physical notch's height unless covering the gap below it is chosen")
        suite.expect(defaults.double(forKey: DefaultsKey.notchHoverDelay) == 0.25,
               "hover activation defaults to a deliberate quarter-second pause")
        for value in [0.10, 0.25, 0.65, 1.0] {
            suite.expect(NotchSupport.sanitizedHoverDelay(value) == value, "valid hover activation times are preserved")
        }
        suite.expect(NotchSupport.sanitizedHoverDelay(-1) == 0.10
               && NotchSupport.sanitizedHoverDelay(9) == 1.0,
               "hover activation times stay within usable bounds")
        suite.expect([Double.nan, .infinity, -.infinity].allSatisfy { NotchSupport.sanitizedHoverDelay($0) == 0.25 },
               "non-finite hover activation times fall back to the default")
        suite.expect(defaults.double(forKey: DefaultsKey.notchCloseDelay) == 0.18
               && NotchSupport.sanitizedCloseDelay(0.65) == 0.65
               && NotchSupport.sanitizedCloseDelay(-1) == 0.10 && NotchSupport.sanitizedCloseDelay(9) == 2.0
               && NotchSupport.sanitizedCloseDelay(.nan) == 0.18,
               "closing after the pointer leaves keeps its old pause and stays within usable bounds")
        defaults.set(1.5, forKey: DefaultsKey.notchCloseDelay)
        suite.expect(NotchSupport.closeDelay(in: defaults) == 1.5,
                     "the closing delay reads the saved preference")
        defaults.set("invalid", forKey: DefaultsKey.notchCloseDelay)
        suite.expect(NotchSupport.closeDelay(in: defaults) == 0.18,
                     "a closing delay stored with the wrong type uses the default")
        defaults.removeObject(forKey: DefaultsKey.notchCloseDelay)
        suite.expect(NotchSupport.closeDelay(in: defaults) == 0.18,
                     "removing the closing preference restores the original delay")
        suite.expect(!NotchSupport.routesAppPanel(in: defaults) && NotchSupport.routesClipboardWindow(in: defaults),
               "enabling a fresh island keeps the app panel separate and routes the clipboard window into it")
        let initialLayout = NotchQuickAccessConfiguration.current(in: defaults)
        suite.expect(initialLayout == NotchQuickAccessConfiguration.current(in: defaults),
               "default buttons keep stable identities across preference refreshes")
        let storedLayout = NotchQuickAccessConfiguration.stored(in: defaults)
        defaults.set(false, forKey: AppFeature.notchAgents.availabilityKey)
        suite.expect(NotchQuickAccessConfiguration.stored(in: defaults) == storedLayout,
               "uninstalling a section preserves its configured position")
        defaults.set(true, forKey: AppFeature.notchAgents.availabilityKey)
        suite.expect(NotchQuickAccessConfiguration.current(in: defaults) == initialLayout,
               "reinstalled sections return to their original positions")
        defaults.set("system", forKey: DefaultsKey.notchHiddenModules)
        var held = NotchQuickAccessConfiguration(side: .left, actions: [.explore, .module(.system), .settings])
        let incoming = NotchQuickButton(action: .control(.panel), side: .right)
        held.buttons.append(incoming)
        held.move(incoming.id, to: .left)
        suite.expect(!held.hasRoom(on: .left) && held.buttons.first(where: { $0.id == incoming.id })?.side == .right
               && held.buttons.filter { $0.side == .left }.compactMap(\.action) == [.explore, .module(.system), .settings],
               "a hidden button keeps its place, so a side it fills takes no other")
        var reordered = NotchQuickAccessConfiguration(side: .left, actions: [.explore, .module(.system), .settings])
        let ids = reordered.buttons.map(\.id)
        let swapped = reordered.reorder(ids[2], by: -1)
        let pastTheTop = reordered.reorder(ids[0], by: -1)
        suite.expect(swapped && !pastTheTop && reordered.actions == [.explore, .settings, .module(.system)],
               "moving a button swaps it with its neighbour, hidden or not, and a move past either end changes nothing")
        let savedIdle = defaults.object(forKey: DefaultsKey.notchIdleContent)
        defaults.set("", forKey: DefaultsKey.notchHiddenModules)
        suite.expect(NotchQuickAccessConfiguration.current(in: defaults) == initialLayout,
               "a section switched back on returns its button to its place")
        let saved = [DefaultsKey.notchEnabled, AppFeature.notchAgents.availabilityKey, DefaultsKey.notchAgentsEnabled,
                     AppFeature.monitorPower.availabilityKey].map { ($0, defaults.object(forKey: $0)) }
        defaults.set(false, forKey: DefaultsKey.notchEnabled)
        defaults.set(true, forKey: AppFeature.notchAgents.availabilityKey)
        defaults.set(true, forKey: DefaultsKey.notchAgentsEnabled)
        defaults.set(NotchIdleContent.agents.rawValue, forKey: DefaultsKey.notchIdleContent)
        suite.expect(NotchSupport.canRest(with: .agents, in: defaults) && NotchSupport.idleContent(in: defaults) == .agents,
               "the island's own switch leaves an AI resting choice as it is")
        defaults.set("agents", forKey: DefaultsKey.notchHiddenModules)
        suite.expect(!NotchSupport.canRest(with: .agents, in: defaults) && NotchSupport.idleContent(in: defaults) == .none
               && defaults.string(forKey: DefaultsKey.notchIdleContent) == NotchIdleContent.agents.rawValue,
               "a resting choice whose section is hidden waits, still chosen, while the island rests empty")
        defaults.set("", forKey: DefaultsKey.notchHiddenModules)
        suite.expect(NotchSupport.idleContent(in: defaults) == .agents,
               "the island rests with a waiting choice again once its section is back")
        defaults.set(false, forKey: DefaultsKey.notchAgentsEnabled)
        suite.expect(!NotchSupport.canRest(with: .agents, in: defaults) && NotchSupport.idleContent(in: defaults) == .none,
               "an AI resting choice waits while its section is off, and the island rests empty meanwhile")
        defaults.set(false, forKey: AppFeature.monitorPower.availabilityKey)
        defaults.set(NotchIdleContent.battery.rawValue, forKey: DefaultsKey.notchIdleContent)
        suite.expect(!NotchSupport.canRest(with: .battery, in: defaults) && NotchSupport.idleContent(in: defaults) == .none,
               "a battery resting choice waits while power monitoring is uninstalled")
        for (key, value) in saved { defaults.set(value, forKey: key) }
        defaults.set(savedIdle, forKey: DefaultsKey.notchIdleContent)
        defaults.set("right", forKey: DefaultsKey.notchQuickAccessSide)
        suite.expect(NotchQuickAccessConfiguration.stored(in: defaults) == .init(side: .right, actions: [.explore, .settings]),
               "a saved legacy side retains the former Settings companion")
        defaults.set("", forKey: DefaultsKey.notchQuickAccessSecond)
        suite.expect(NotchQuickAccessConfiguration.stored(in: defaults) == .init(side: .right, actions: [.explore]),
               "an explicitly empty legacy action stays empty under the new defaults")
        defaults.removeObject(forKey: DefaultsKey.notchQuickAccessSide)
        defaults.removeObject(forKey: DefaultsKey.notchQuickAccessSecond)
        let idleGeometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                        safeAreaTop: 32, cameraWidth: 180, compactSideRoom: 100)
        suite.expect(idleGeometry.restingSize(showsContent: NotchSupport.idleContent(in: defaults) != .none)
               == CGSize(width: 180, height: 32),
               "an island resting empty shrinks to the physical camera without reserving empty side space")
        defaults.set(NotchIdleContent.battery.rawValue, forKey: DefaultsKey.notchIdleContent)
        suite.expect(NotchSupport.idleContent(in: defaults) == .battery,
               "battery at rest shows while power monitoring is installed")
        defaults.set(false, forKey: AppFeature.monitorPower.availabilityKey)
        suite.expect(NotchSupport.idleContent(in: defaults) == .none, "unavailable battery cannot appear while idle")
        defaults.set(true, forKey: AppFeature.monitorPower.availabilityKey)
        defaults.set("clock", forKey: DefaultsKey.notchIdleContent)
        suite.expect(NotchSupport.idleContent(in: defaults) == .none,
               "the retired clock falls back to nothing, including restored settings")
        defaults.set("music", forKey: DefaultsKey.notchIdleContent)
        suite.expect(NotchSupport.idleContent(in: defaults) == .none,
               "the retired music option falls back to nothing")
        defaults.set("controls", forKey: DefaultsKey.notchIdleContent)
        suite.expect(NotchSupport.idleContent(in: defaults) == .none,
               "the retired controls idle option falls back to nothing")
        defaults.set(NotchIdleContent.none.rawValue, forKey: DefaultsKey.notchIdleContent)
        suite.expect(NotchControlItem.allCases.filter { $0.setupRequirement == .none } == [.panel],
                     "every unavailable island control with a setup path has a navigation target")
        let savedHiddenControls = defaults.string(forKey: DefaultsKey.notchHiddenControls)
        defaults.removeObject(forKey: DefaultsKey.notchHiddenControls)
        defaults.set("", forKey: DefaultsKey.notchHiddenControls)
        defaults.set(savedHiddenControls, forKey: DefaultsKey.notchHiddenControls)
        defaults.set("panel,panel,unknown,speedTest", forKey: DefaultsKey.notchControlOrder)
        defaults.set("volume,screenshot", forKey: DefaultsKey.notchHiddenControls)
        let controls = NotchSupport.controls(in: defaults)
        suite.expect(controls.first == .panel && Set(controls).count == controls.count,
               "shortcut ordering tolerates duplicate and obsolete identifiers")
        defaults.set("", forKey: DefaultsKey.notchHiddenControls)
        defaults.set("", forKey: DefaultsKey.notchControlOrder)
        let allModules = NotchModule.allCases
        suite.expect(Set(allModules.map(\.shortcutKey)).count == allModules.count,
               "every section has a unique direct shortcut, including destinations after the ninth")
        for module in allModules {
            suite.expect(NotchSupport.moduleShortcut(module.shortcutKey, modules: allModules.reversed()) == module
                   && NotchSupport.moduleShortcut(module.shortcutKey.uppercased(), modules: allModules) == module,
                   "direct section shortcuts remain stable across ordering and letter case")
            suite.expect(NotchSupport.moduleShortcut(module.shortcutKey, modules: allModules.filter { $0 != module }) == nil,
                   "hidden or unavailable sections cannot be opened by their shortcut")
        }
        for characters in ["", "0", "9", "10", "cc", "-1", " "] {
            suite.expect(NotchSupport.moduleShortcut(characters, modules: allModules) == nil,
                   "unassigned keys cannot navigate")
        }
        suite.expect(NotchSupport.moduleShortcut("c", modules: []) == nil,
               "direct shortcuts tolerate an empty gallery")
        var reached = Set<NotchModule>()
        var current: NotchModule? = allModules.first
        for _ in allModules {
            if let current { reached.insert(current) }
            current = NotchSupport.adjacentModule(to: current, modules: allModules, backwards: false)
        }
        suite.expect(reached == Set(allModules) && current == allModules.first,
               "keyboard cycling reaches every section and wraps without a nine-item limit")
        suite.expect(NotchSupport.clipboardPasteTarget(highlighted: nil, in: [1, 2, 3]) == 1
                && NotchSupport.clipboardPasteTarget(highlighted: 2, in: [1, 2, 3]) == 2
                && NotchSupport.clipboardPasteTarget(highlighted: 9, in: [1, 2, 3]) == 1
                && NotchSupport.clipboardPasteTarget(highlighted: 2, in: [Int]()) == nil,
               "Return pastes the highlighted or first visible clipboard entry, and nothing from an empty list")
        // Opening the page highlights what was copied last, which is the first recent entry below any pinned ones.
        suite.expect(NotchSupport.restingClipboardHighlight([(1, true), (2, true), (3, false), (4, false)]) == 3
                && NotchSupport.restingClipboardHighlight([(1, true), (2, true)]) == 1
                && NotchSupport.restingClipboardHighlight([(5, false)]) == 5
                && NotchSupport.restingClipboardHighlight([(Int, Bool)]()) == nil,
               "the clipboard opens on the entry copied last, not on a pinned one, and on the top pinned one when only those exist")
        func key(_ code: UInt16, _ characters: String = "", _ modifiers: NSEvent.ModifierFlags = [],
                 composing: Bool = false) -> NotchClipboardKey? {
            NotchSupport.clipboardKey(keyCode: code, characters: characters, modifiers: modifiers, composing: composing)
        }
        suite.expect(key(126) == .move(backwards: true) && key(125) == .move(backwards: false)
                && key(36) == .paste && key(76) == .paste,
               "the arrow keys and Return drive the list while the search field has the focus")
        suite.expect(key(45, "n", .control) == key(125) && key(35, "p", .control) == key(126)
                && key(0, "N", [.control, .capsLock]) == key(125) && key(2, "P", .control) == key(126),
               "Control-N/P follow the layout's letter and move like the arrows, including with Caps Lock")
        suite.expect(key(45, "n", .control, composing: true) == nil
                && key(35, "p", .control, composing: true) == nil,
               "Control-N/P stay with an input method while it composes")
        for modifiers: NSEvent.ModifierFlags in [.command, .option, [.control, .shift],
                                                 [.control, .command], [.control, .option]] {
            suite.expect(key(45, "n", modifiers) == nil && key(35, "p", modifiers) == nil,
                   "other shortcuts with N/P do not move the clipboard highlight")
        }
        suite.expect(key(0, "a") == .reveal && key(0, "Ab") == .reveal && key(0, "ñ") == .reveal && key(40, "ㅎ") == .reveal
                && key(45, "n") == .reveal && key(35, "p") == .reveal
                && key(49, " ") == nil && key(48, "\t") == nil && key(51, "\u{7f}") == nil
                && key(125, "\u{F701}") == .move(backwards: false),
               "a typed letter shows the search field and goes on to it, while a space and control keys stay as they are")
        // Japanese, Chinese and Korean input and the accent keys compose in
        // the field: its keys, Return and the arrows included, are the input method's.
        suite.expect(key(36, composing: true) == .reveal && key(125, composing: true) == .reveal
                && key(0, "a", composing: true) == .reveal && key(36, "", .command, composing: true) == nil,
               "every key goes on to an input method while it composes")
        suite.expect(key(36, "", .command) == nil && key(18, "1", .command) == nil && key(0, "a", .command) == nil
                && key(0, "a", .control) == nil && key(0, "å", .option) == nil,
               "keys held with Command, Control or Option are left to their own shortcuts")
        // Arrow keys carry the numeric pad and function flags, which change nothing.
        suite.expect(key(125, "\u{F701}", [.shift, .numericPad, .function]) == nil && key(126, "", .shift) == nil
                && key(36, "\r", .shift) == nil && key(76, "\u{3}", .shift) == nil
                && key(0, "A", .shift) == .reveal && key(125, "\u{F701}", [.numericPad, .function]) == .move(backwards: false),
               "Shift with an arrow or Return is left to the search field, while a capital letter still shows it")
        // An open entry is drawn over the list from its row and stays in view
        // without the list scrolling: up where it would pass the bottom, down
        // to the top where its row is partly scrolled away.
        func openOffset(_ rowTop: CGFloat, _ height: CGFloat, in visible: CGFloat) -> CGFloat {
            NotchSupport.clipboardOpenOffset(rowTop: rowTop, rowHeight: 52, height: height, visibleHeight: visible)
        }
        suite.expect(openOffset(20, 120, in: 200) == 0 && openOffset(140, 120, in: 200) == -60
                && openOffset(170, 120, in: 200) == -90 && openOffset(-20, 120, in: 200) == 20
                && openOffset(60, 200, in: 200) == -60,
               "an open clipboard entry stays within the list over the row it opened from")
        // Once its row has scrolled out of the list, the open entry goes on
        // from the row's edge with it, instead of staying over other rows.
        suite.expect(openOffset(-52, 150, in: 300) == 52 && openOffset(-200, 150, in: 300) == 52
                && openOffset(300, 150, in: 300) == -150 && openOffset(400, 150, in: 300) == -150,
               "an open clipboard entry scrolls away with its row once the row has left the list")
        // As the page opens, the list is at its top: rows 8 apart, of which
        // the highlighted one needs 26 points in view.
        func openingScroll(_ index: Int, in visible: CGFloat, rowHeight: CGFloat = 104) -> Int {
            NotchSupport.clipboardOpeningScroll(index: index, rowHeight: rowHeight, spacing: 8, shown: 26,
                                                visibleHeight: visible)
        }
        suite.expect(openingScroll(1, in: 180) == 0 && openingScroll(2, in: 264) == 0 && openingScroll(2, in: 250) == 0
                && openingScroll(2, in: 172, rowHeight: 52) == 0 && openingScroll(0, in: 20) == 0,
               "a clipboard list opens at its top while the highlighted row shows its top")
        suite.expect(openingScroll(2, in: 249) == 1 && openingScroll(2, in: 180) == 1 && openingScroll(3, in: 264) == 1
                && openingScroll(4, in: 264, rowHeight: 52) == 1 && openingScroll(3, in: 20) == 3,
               "a clipboard list that must move to show the highlighted row moves by the fewest whole rows")
        suite.expect(NotchSupport.steppedItem(from: nil, in: [1, 2, 3], backwards: false) == 1
               && NotchSupport.steppedItem(from: nil, in: [1, 2, 3], backwards: true) == 1
               && NotchSupport.steppedItem(from: 1, in: [1, 2, 3], backwards: false) == 2
               && NotchSupport.steppedItem(from: 3, in: [1, 2, 3], backwards: false) == 3
               && NotchSupport.steppedItem(from: 1, in: [1, 2, 3], backwards: true) == 1
               && NotchSupport.steppedItem(from: 9, in: [1, 2, 3], backwards: true) == 1
               && NotchSupport.steppedItem(from: 1, in: [Int](), backwards: false) == nil,
               "clipboard arrow keys start at the top result, stop at the ends and recover from a filtered-out row")
        suite.expect(NotchSupport.searchHighlight(keeping: nil, in: [1, 2, 3], query: "note") == 1
               && NotchSupport.searchHighlight(keeping: nil, in: [1, 2, 3], query: " \n ") == nil
               && NotchSupport.searchHighlight(keeping: 2, in: [1, 2, 3], query: "note") == 2
               && NotchSupport.searchHighlight(keeping: 2, in: [1, 2, 3], query: "") == 2
               && NotchSupport.searchHighlight(keeping: 9, in: [1, 2, 3], query: "note") == 1
               && NotchSupport.searchHighlight(keeping: 9, in: [1, 2, 3], query: "") == nil
               && NotchSupport.searchHighlight(keeping: nil, in: [Int](), query: "note") == nil,
               "a typed clipboard search highlights its top result for Return, and an empty one waits for an arrow")
        suite.expect(NotchSupport.filteredModules(allModules, query: "", title: { $0.rawValue }) == allModules
               && NotchSupport.filteredModules(allModules, query: "unmatched", title: { $0.rawValue }).isEmpty,
               "empty queries preserve configured ordering and unmatched queries have no action")
        suite.expect(!NotchSupport.closesOnPointerExit(expanded: true, peeking: false, openedByHover: false),
               "menu bar and keyboard openings survive a pointer outside the notch")
        suite.expect(NotchSupport.closesOnPointerExit(expanded: true, peeking: false, openedByHover: true)
               && NotchSupport.closesOnPointerExit(expanded: false, peeking: true, openedByHover: false),
               "hover presentations still close when the pointer leaves")
        var hover = NotchHoverState()
        hover.close(pointerInside: true)
        for _ in 0..<4 { hover.update(pointerInside: true) }
        suite.expect(hover.suppressed, "closing under the pointer survives repeated hover events caused by resizing")
        hover.update(pointerInside: false)
        hover.update(pointerInside: true)
        suite.expect(!hover.suppressed, "leaving and returning rearms hover without a timer")
        hover.close(pointerInside: true)
        hover.open()
        suite.expect(!hover.suppressed, "an intentional opening remains possible while hover is suppressed")
        hover.close(pointerInside: false)
        suite.expect(!hover.suppressed, "closing away from the island does not block the next approach")
        let topArea = idleGeometry.activationArea(in: idleGeometry.expanded, hasHeader: true, compactActivity: false)
        let screenTop = CGPoint(x: idleGeometry.screen.midX, y: idleGeometry.screen.maxY)
        suite.expect(idleGeometry.contains(screenTop, in: idleGeometry.collapsed)
               && !idleGeometry.contains(CGPoint(x: screenTop.x, y: screenTop.y + 0.5), in: idleGeometry.collapsed)
               && !idleGeometry.contains(CGPoint(x: idleGeometry.screen.minX, y: screenTop.y), in: idleGeometry.collapsed),
               "hover includes the exact screen top without accepting points above or beside the island")
        hover.close(pointerInside: true)
        hover.update(pointerInside: idleGeometry.contains(screenTop, in: idleGeometry.collapsed))
        suite.expect(hover.suppressed, "the physical screen edge cannot rearm hover after an explicit close")
        suite.expect(topArea.contains(CGPoint(x: idleGeometry.expanded.width / 2, y: 1))
               && topArea.maxY == idleGeometry.safeContentTop,
               "the very top is clickable while section buttons below it keep their own actions")
        let footerGeometry = NotchGeometry(screen: idleGeometry.screen, safeAreaTop: 32, cameraWidth: 180, compactSideRoom: 0)
        suite.expect(footerGeometry.activationArea(in: footerGeometry.compactActivitySize, hasHeader: false, compactActivity: true).maxY
               == footerGeometry.compactActivityTopPadding,
               "top activation does not cover timer and download controls in the footer")
        let plainGeometry = NotchGeometry(screen: idleGeometry.screen, safeAreaTop: 0, cameraWidth: 0, compactSideRoom: 0)
        suite.expect(plainGeometry.activationArea(in: plainGeometry.compactActivitySize, hasHeader: false, compactActivity: true).width == plainGeometry.cameraWidth,
               "the simulated camera leaves the activity controls beside it independently clickable")
        defaults.set(true, forKey: DefaultsKey.clipboardHistoryEnabled)
        suite.expect(NotchSupport.routes(.clipboard, in: defaults), "installed clipboard activity starts once history capture is enabled")
        defaults.set("", forKey: DefaultsKey.notchHiddenModules)
        suite.expect(NotchSupport.routesClipboardWindow(in: defaults), "clipboard opening defaults to the enabled island")
        defaults.set(false, forKey: DefaultsKey.notchClipboardWindow)
        suite.expect(!NotchSupport.routesClipboardWindow(in: defaults), "clipboard can still use its separate window")
        defaults.set(true, forKey: DefaultsKey.notchClipboardWindow)
        defaults.set("clipboard,unknown", forKey: DefaultsKey.notchHiddenModules)
        suite.expect(!NotchSupport.routesClipboardWindow(in: defaults), "hidden clipboard keeps the ordinary history available")
        suite.expect(!NotchSupport.routes(.clipboard, in: defaults), "hidden module cannot leak an activity")
        defaults.set("system,music,system,unknown", forKey: DefaultsKey.notchModuleOrder)
        defaults.set(true, forKey: DefaultsKey.notchAgentsEnabled)
        suite.expect(NotchSupport.modules(in: defaults) == [.system, .controls, .agents],
               "module order ignores unknown ids and duplicates, preserving newly added modules")
        defaults.set(false, forKey: AppFeature.notch.availabilityKey)
        suite.expect(!NotchSupport.isEnabled(in: defaults), "hub is stronger than the notch master switch")
        suite.expect(!NotchSupport.usesHapticFeedback(in: defaults), "removing the feature also gates tactile feedback")
        suite.expect(NotchEvent.allCases.allSatisfy { !NotchSupport.routes($0, in: defaults) },
               "hub removal gates every notch event")

        defaults.set("unknown", forKey: DefaultsKey.notchQuickAccessSide)
        defaults.set("settings", forKey: DefaultsKey.notchQuickAccessSecond)
        defaults.set("settings", forKey: DefaultsKey.notchQuickAccessThird)
        suite.expect(NotchQuickAccessConfiguration.current(in: defaults) == .init(side: .left, actions: [.explore, .settings]),
               "invalid placement falls back safely and duplicate quick actions are not repeated")
        defaults.set("timer", forKey: DefaultsKey.notchQuickAccessSecond)
        defaults.set("../../unknown", forKey: DefaultsKey.notchQuickAccessThird)
        defaults.set("timer", forKey: DefaultsKey.notchHiddenModules)
        suite.expect(NotchQuickAccessConfiguration.current(in: defaults).actions == [.explore],
               "hidden destinations and unrecognized action identifiers cannot create a floating action")
        defaults.set("", forKey: DefaultsKey.notchHiddenModules)
        for side in [NotchQuickAccessSide.left, .right] {
            let edge: CGFloat = side == .left ? 72 : 632
            for index in 0..<3 {
                let point = NotchQuickAccessLayout.center(index: index, progress: 1, edge: edge, top: 60, side: side)
                suite.expect(NotchQuickAccessLayout.hitTest(point, count: 3, edge: edge, top: 60, side: side),
                       "every visible bubble accepts its own center on either side")
                let gap = CGPoint(x: edge + (side == .left ? -6 : 6), y: point.y)
                suite.expect(!NotchQuickAccessLayout.hitTest(gap, count: 3, edge: edge, top: 60, side: side),
                       "the transparent gap between a bubble and the notch does not claim clicks")
            }
        }
        suite.expect(NotchQuickAccessLayout.hoverRect(count: 0, edge: 72, top: 60, side: .left).isNull,
               "no floating actions means no extra hover surface")
        for side in [NotchQuickAccessSide.left, .right] {
            for count in 1...3 {
                let edge: CGFloat = side == .left ? 86 : 618
                let region = NotchQuickAccessLayout.hoverRect(count: count, edge: edge, top: 60, side: side)
                let first = NotchQuickAccessLayout.center(index: 0, progress: 1, edge: edge, top: 60, side: side)
                let last = NotchQuickAccessLayout.center(index: count - 1, progress: 1, edge: edge, top: 60, side: side)
                let start = side == .left ? first.x - 34 : edge - 12
                let end = side == .left ? edge + 12 : first.x + 34
                let pathIsCovered = stride(from: start, through: end, by: 1).allSatisfy { x in
                    stride(from: first.y - 30, through: last.y + 30, by: 1).allSatisfy { y in
                        region.contains(CGPoint(x: x, y: y))
                    }
                }
                suite.expect(pathIsCovered, "hover remains continuous through gaps, between buttons and around their edges")
                let outside = CGPoint(x: side == .left ? region.minX - 1 : region.maxX + 1, y: first.y)
                suite.expect(!region.contains(outside), "moving beyond the forgiving hover region still permits closing")
            }
        }
        for side in NotchQuickAccessSide.allCases {
            for count in 1...3 {
                for height: CGFloat in [120, 190, 280, 400] {
                    let body = CGRect(x: 72, y: 0, width: 440, height: height)
                    let configuration = NotchQuickAccessConfiguration(buttons:
                        (0..<count).map { _ in NotchQuickButton(action: .settings, side: side) })
                    let values = NotchQuickAccessLayout.placements(configuration, body: body, headerTop: 61)
                    let first = values.first!.center(progress: 1)
                    let last = values.last!.center(progress: 1)
                    if side == .bottom {
                        suite.expect((first.x + last.x) / 2 == body.midX && first.y == body.maxY + 34,
                                     "bottom actions stay centered beneath the island")
                    } else {
                        suite.expect(first.y >= 34 && first.y <= 61 && last.y - first.y == CGFloat(count - 1) * 54,
                                     "side actions retain their size and spacing without crossing the top edge")
                        if height == 190 && count == 3 {
                            suite.expect(first.y == 41 && last.y == 149,
                                         "three actions balance the margins of a short compact page")
                        }
                        if height >= 280 {
                            suite.expect(first.y == 61, "roomy pages retain their header-aligned actions")
                        }
                        let hover = NotchQuickAccessLayout.hoverRect(count: count, edge: values[0].edge,
                                                                    top: values[0].top, side: side)
                        suite.expect(values.allSatisfy { hover.contains($0.center(progress: 1)) },
                                     "the hover corridor follows the adapted button positions")
                    }
                }
            }
        }
        // Two on the left and three on the right, beside a short page.
        let uneven = NotchQuickAccessConfiguration(buttons:
            [NotchQuickAccessSide.left, .left, .right, .right, .right].map { NotchQuickButton(action: .settings, side: $0) })
        let level = NotchQuickAccessLayout.placements(uneven, body: CGRect(x: 72, y: 0, width: 440, height: 178), headerTop: 61)
        suite.expect(level[0].top == level[2].top && level[0].top < 61,
                     "a short page lifts both side columns together, so they start level")
        let legacy = NotchQuickAccessConfiguration.stored(in: defaults)
        suite.expect(legacy == NotchQuickAccessConfiguration.stored(in: defaults),
               "legacy quick-access migration keeps stable identities across refreshes")
        let placements = [NotchQuickButton(action: .explore, side: .left),
                          NotchQuickButton(action: .settings, side: .right),
                          NotchQuickButton(action: .control(.keepAwake), side: .bottom)]
        var layout = NotchQuickAccessConfiguration(buttons: placements)
        defaults.set(layout.encoded, forKey: DefaultsKey.notchQuickAccessLayout)
        suite.expect(NotchQuickAccessConfiguration.stored(in: defaults) == layout,
               "the visual layout stores all three edges and direct actions together")
        layout.move(placements[0].id, to: .bottom, before: placements[2].id)
        suite.expect(layout.buttons.first(where: { $0.id == placements[0].id })?.side == .bottom
               && layout.buttons.filter { $0.side == .bottom }.map(\.id) == [placements[0].id, placements[2].id],
               "moving a button preserves its identity and inserts it in the chosen order")
        let crowded = NotchQuickAccessConfiguration(buttons: (0..<12).map { _ in NotchQuickButton(action: .settings, side: .bottom) })
        defaults.set(crowded.encoded, forKey: DefaultsKey.notchQuickAccessLayout)
        suite.expect(crowded.sanitized().buttons.count == 3 && NotchQuickAccessConfiguration.current(in: defaults).buttons.count == 3,
               "restored layouts cannot overfill an edge")
        var invalidButton = NotchQuickButton(action: .settings, side: .left, label: "  Name\nwith line  ")
        invalidButton.actionID = "unrecognized-action"
        suite.expect(NotchQuickAccessConfiguration(buttons: [invalidButton]).sanitized().buttons.isEmpty,
               "unknown restored actions cannot run")
        let emptyLayout = NotchQuickAccessConfiguration(buttons: [])
        defaults.set(emptyLayout.encoded, forKey: DefaultsKey.notchQuickAccessLayout)
        suite.expect(NotchQuickAccessConfiguration.stored(in: defaults).buttons.isEmpty,
               "an intentionally empty layout does not resurrect legacy buttons")
        defaults.removeObject(forKey: DefaultsKey.notchQuickAccessLayout)
        let bottomRegion = NotchQuickAccessLayout.hoverRect(count: 3, edge: 300, top: 150, side: .bottom)
        suite.expect(bottomRegion.contains(CGPoint(x: 204, y: 307)) && bottomRegion.contains(CGPoint(x: 204, y: 364)),
               "bottom buttons retain a continuous forgiving path back to the island")
        suite.expect(AppFeature.notch.settingsDestination.page == .notch, "hub routes to notch settings")
        suite.expect(!FeatureVisibilitySupport.isPageVisible(.notch, isAvailable: { !FeatureVisibilitySupport.features(for: .notch).contains($0) }),
               "notch settings disappear when uninstalled")

        for language in AppLanguage.allCases {
            for child in Mirror(reflecting: FeatureStrings.notch(language)).children {
                let value = child.value as? String ?? ""
                suite.expect(!value.isEmpty && !value.contains("—"),
                       "notch localized text is present and human-readable: \(language) \(child.label ?? "")")
            }
        }

        let frames = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                      CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                      CGRect(x: 100, y: 982, width: 900, height: 1440),
                      CGRect(x: 0, y: 0, width: 640, height: 480)]
        let compact = NotchGeometry(screen: frames[0], safeAreaTop: 32, cameraWidth: 210)
        let spacious = NotchGeometry(screen: frames[0], safeAreaTop: 32, cameraWidth: 210, layout: .spacious)
        let tall = NotchGeometry(screen: frames[0], safeAreaTop: 32, cameraWidth: 210, layout: .custom, customHeight: 640)
        for geometry in [compact, spacious, tall] {
            suite.expect(geometry.sectionPickerSize(count: 1).height
                            < geometry.sectionPickerSize(count: geometry.sectionColumns + 1).height,
                   "a short search result shrinks the gallery instead of reserving empty rows")
        }
        // More sections than a preset's page holds, as a long search result list has.
        let manySections = 16
        suite.expect(compact.sectionRows(count: manySections) == 3 && spacious.sectionRows(count: manySections) == 3
               && compact.contentSize(for: compact.sectionPickerSize(count: manySections)).height <= compact.pageBudget
               && tall.sectionRows(count: manySections) > spacious.sectionRows(count: manySections)
               && tall.sectionRows(count: manySections)
                   <= NotchSectionPaging.rows(count: manySections, columns: tall.sectionColumns),
               "the gallery is a page: presets show three whole rows and a tall island shows more")
        suite.expect(compact.sectionColumns == 4 && spacious.sectionColumns == 5
               && compact.sectionColumns * compact.sectionRows(count: manySections) < manySections
               && spacious.sectionColumns * (spacious.sectionRows(count: manySections) + 1) >= manySections,
               "a compact island steps rows to reach its last sections and a spacious one steps at most one")
        suite.expect(NotchLayout.sectionTileHeight * 2 + NotchLayout.sectionSpacing <= NotchLayout.compactContentHeight
               && NotchLayout.sectionTileHeight * 3 + NotchLayout.sectionSpacing * 2 <= NotchLayout.pageContentHeight,
               "two rows fit the compact strip and three rows fit the gallery's page exactly or better")
        for geometry in [compact, spacious, tall] {
            let columns = geometry.sectionColumns
            let tileWidth = (geometry.contentWidth - NotchLayout.sectionIndicatorWidth
                             - CGFloat(columns - 1) * NotchLayout.sectionSpacing) / CGFloat(columns)
            suite.expect(tileWidth >= NotchLayout.sectionTileWidth,
                   "gallery tiles keep their readable width beside the row indicator")
        }
        suite.expect(compact.contentSize(for: compact.sectionPickerSize(count: 0)).height == NotchLayout.emptyHeight
               && compact.contentSize(for: compact.sectionPickerSize(count: 1)).height == NotchLayout.sectionTileHeight,
               "an unmatched search keeps the recovery guidance's row and a match takes just its tiles, the search living in the header")
        for layout in NotchSize.allCases {
            let geometry = NotchGeometry(screen: frames[0], safeAreaTop: 32, cameraWidth: 210, layout: layout)
            for module in NotchModule.allCases {
                let content = geometry.contentSize(for: geometry.expandedSize(module: module)).height
                suite.expect(content <= geometry.contentBudget && content > 0,
                       "every page stays inside its preset's strip: \(layout) \(module)")
            }
            let detail = { (height: CGFloat, panel: Bool) in
                geometry.contentSize(for: geometry.expandedSize(module: .system, detail: true, panel: panel,
                                                                detailHeight: height)).height
            }
            suite.expect(detail(140, false) == 144 && detail(900, false) == geometry.pageBudget
                   && detail(140, true) == geometry.pageBudget,
                   "a measured detail such as Fan Control fits its card within the page instead of a tall empty page: \(layout)")
        }
        suite.expect(compact.contentBudget == NotchLayout.compactContentHeight && spacious.contentBudget == NotchLayout.spaciousContentHeight
               && compact.expanded.height < compact.expanded.width && spacious.expanded.height < spacious.expanded.width,
               "both presets are strips wider than they are tall")
        suite.expect(compact.expanded.width >= 440 && spacious.expanded.width > compact.expanded.width,
               "the standard notch has room for side-by-side controls while spacious remains available")
        for width in [360.0, 480.0, 600.0] {
            for height in [NotchSize.heightRange.lowerBound, 640.0] {
                let geometry = NotchGeometry(screen: frames[0], safeAreaTop: 32, cameraWidth: 210,
                                             layout: .custom, customWidth: width, customHeight: height)
                for shortcuts in 0...12 {
                    let size = geometry.expandedSize(module: .controls, shortcutCount: shortcuts)
                    let content = geometry.contentSize(for: size)
                    let planned = NotchLayout.controls(shortcutCount: shortcuts,
                                                       width: geometry.contentWidth, height: geometry.contentBudget)
                    let drawn = NotchLayout.controls(shortcutCount: shortcuts, width: content.width, height: content.height)
                    suite.expect(content.height == min(geometry.contentBudget, shortcuts == 0 ? NotchLayout.emptyHeight : planned.height),
                           "the home page takes the rows it needs and never more than the custom budget")
                    suite.expect(planned == drawn, "the page rebuilds the same rows from the height it receives")
                    suite.expect(frames[0].contains(geometry.frame(for: size)),
                           "the full controls surface stays inside the display")
                }
            }
        }
        for frame in frames {
            for width in [360.0, 470.0, 600.0] {
                for height in [NotchSize.heightRange.lowerBound, 400.0, 520.0, 640.0] {
                    let custom = NotchGeometry(screen: frame, safeAreaTop: 32, cameraWidth: 210,
                                               layout: .custom, customWidth: width, customHeight: height)
                    let available = height - custom.headerTopInset - custom.headerChromeHeight
                    suite.expect(custom.contentBudget == available, "a custom island's budget is what its height leaves below the chrome")
                    for module in NotchModule.allCases {
                        let size = custom.expandedSize(module: module)
                        suite.expect(size.width == min(width, frame.width - 24 - NotchQuickAccessLayout.gutter * 2) && size.height <= height
                               && frame.contains(custom.frame(for: size)),
                               "custom dimensions fit every module and respect the display and height limit")
                        suite.expect(custom.contentSize(for: size).height <= available && custom.contentSize(for: size).height > 0,
                               "every page keeps inside the custom budget")
                    }
                    for count in [0, 1, 9, allModules.count] {
                        let picker = custom.sectionPickerSize(count: count)
                        suite.expect(picker.width == custom.expandedWidth && picker.height <= height
                               && frame.contains(custom.frame(for: picker)),
                               "gallery dimensions respect the display and the user's height limit at every item count")
                    }
                    suite.expect(custom.expandedSize(module: .clipboard).height == min(height, frame.height - 48),
                           "long lists use the chosen height without overflowing a shorter display")
                }
            }
        }
        for invalid in [Double.nan, .infinity, -.infinity, -200, 0, 1e9] {
            let custom = NotchGeometry(screen: frames[0], safeAreaTop: 32, cameraWidth: 210, layout: .custom,
                                       customWidth: invalid, customHeight: invalid)
            suite.expect(NotchSize.widthRange.contains(custom.customWidth) && NotchSize.heightRange.contains(custom.customHeight)
                   && frames[0].contains(custom.frame(for: custom.expandedSize(module: .clipboard))),
                   "invalid imported dimensions cannot create an unbounded or off-screen panel")
        }
        let wideCamera = NotchGeometry(screen: frames[0], safeAreaTop: 32, cameraWidth: 390, layout: .custom,
                                       customWidth: 360)
        suite.expect(wideCamera.expanded.width > wideCamera.cameraWidth,
               "a requested narrow panel still clears a wider physical camera")
        for frame in frames {
            for notch in [false, true] {
                let geometry = NotchGeometry(screen: frame, safeAreaTop: notch ? 32 : 0,
                                             cameraWidth: notch ? 210 : 0)
                for size in [geometry.collapsed, geometry.notice, geometry.noticeSize(wingWidth: 190), geometry.expanded] {
                    let positioned = geometry.frame(for: size)
                    suite.expect(frame.contains(positioned), "notch fits displays in every coordinate quadrant")
                    suite.expect(positioned.midX == frame.midX, "notch stays centered while morphing")
                    suite.expect(positioned.maxY == frame.maxY,
                           "top edge does not jump across presentation states")
                }
                suite.expect(geometry.activityWingWidth * 2 + geometry.cameraWidth == geometry.activityStrip.width,
                       "an activity's strip uses equal wings around the camera")
                suite.expect(geometry.frame(for: geometry.activityStrip).maxY == frame.maxY,
                       "the lateral activity strip remains attached to the same top edge")
                let quiet = geometry.restingSize(showsContent: false)
                suite.expect(quiet.width == geometry.cameraWidth && quiet.height <= geometry.menuBarHeight,
                       "empty idle does not reserve wings or a footer for unsolicited widgets")
                suite.expect(geometry.contentSize(for: geometry.expanded).height
                       == geometry.expanded.height - geometry.headerTopInset - geometry.headerRowHeight
                           - NotchLayout.spacing - NotchLayout.bottomInset,
                       "content reserves one top navigation row, its spacing and the bottom inset")
                suite.expect(geometry.safeContentTop > geometry.cameraHeight, "controls always clear the physical camera")
            }
        }
        for frame in frames {
            for layout in NotchSize.allCases {
                let geometry = NotchGeometry(screen: frame, safeAreaTop: 32, cameraWidth: 210, layout: layout)
                for module in NotchModule.allCases {
                    let target = geometry.expandedSize(module: module)
                    let envelope = NotchMotion.envelope(from: geometry.notice, to: target)
                    let position = geometry.frame(for: envelope)
                    suite.expect(position.maxY == frame.maxY && position.midX == frame.midX && frame.contains(position),
                           "the animation's backing window stays inside the display and attached to its top center")
                    suite.expect(envelope.width >= geometry.notice.width && envelope.height >= geometry.notice.height
                           && envelope.width >= target.width && envelope.height >= target.height,
                           "the backing window can reveal either endpoint without resizing each frame")
                    suite.expect(NotchMotion.envelope(from: envelope, to: geometry.collapsed) == envelope,
                           "an interrupted closing retains its backing area until the silhouette settles")
                }
                suite.expect(geometry.peek.height <= geometry.cameraHeight + NotchLayout.headerHeight + 32
                       && geometry.peek.height < geometry.expanded.height,
                       "hover reveals a small target instead of the entire panel")
            }
        }
        let menuScreen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let freeRoom = NotchMenuBarLayout.sideRoom(screen: menuScreen, cameraWidth: 180, barHeight: 32,
            occupied: [CGRect(x: 0, y: 924, width: 610, height: 32), CGRect(x: 950, y: 924, width: 520, height: 32)])
        suite.expect(freeRoom == 27, "compact wings stop before the app menu, including its spacing")
        suite.expect(NotchMenuBarLayout.sideRoom(screen: menuScreen, cameraWidth: 180, barHeight: 32,
            occupied: [CGRect(x: 630, y: 924, width: 60, height: 32)]) == nil,
               "occupied camera space cannot be treated as a free menu gap")
        let secondaryMenu = CGRect(x: 1480, y: 924, width: 420, height: 32)
        let primaryStatus = CGRect(x: 950, y: 924, width: 520, height: 32)
        suite.expect(NotchMenuBarLayout.measuredSideRoom(screen: menuScreen, cameraWidth: 180, barHeight: 32,
            menuItems: [secondaryMenu], statusItems: [primaryStatus]) == nil,
               "menus measured only on another display do not prove room on the selected display")
        suite.expect(NotchMenuBarLayout.measuredSideRoom(screen: menuScreen, cameraWidth: 180, barHeight: 32,
            menuItems: [CGRect(x: 0, y: 924, width: 610, height: 32), secondaryMenu],
            statusItems: [primaryStatus]) == 27,
               "menus on another display do not affect a measured gap on the selected display")
        suite.expect(NotchMenuBarLayout.measuredSideRoom(screen: menuScreen, cameraWidth: 180, barHeight: 32,
            menuItems: [], statusItems: [primaryStatus]) == nil,
               "missing menu geometry is not mistaken for an empty menu bar")
        suite.expect(NotchMenuBarLayout.measuredSideRoom(screen: menuScreen, cameraWidth: 180, barHeight: 32,
            menuItems: [CGRect(x: 690, y: 924, width: 80, height: 32)], statusItems: []) == nil,
               "a menu occupying the island's center still hides it")
        let constrained = NotchGeometry(screen: menuScreen, safeAreaTop: 32, cameraWidth: 180,
                                        menuBarHeight: 24, compactSideRoom: freeRoom)
        suite.expect(constrained.collapsed.height == 32 && constrained.activityStrip.height == 32,
               "quiet idle and the lateral strip keep the menu bar's height")
        suite.expect(constrained.restingWingWidth == 0,
               "an indicator is omitted when there is not enough room to render it intact")
        let roomy = NotchGeometry(screen: menuScreen, safeAreaTop: 32, cameraWidth: 180,
                                 menuBarHeight: 24, compactSideRoom: 100)
        let notificationSize = roomy.noticeSize(wingWidth: 190)
        suite.expect(notificationSize.height == roomy.menuBarHeight && roomy.notice.height == notificationSize.height
               && notificationSize.width > roomy.notice.width,
               "notifications use wider wings than level feedback without growing below the menu bar")
        for frame in frames {
            for notched in [false, true] {
                for barHeight: CGFloat in [16, 24, 32, 40, 64] {
                    let geometry = NotchGeometry(screen: frame, safeAreaTop: notched ? 32 : 0,
                        cameraWidth: notched ? 210 : 0, menuBarHeight: barHeight)
                    for wing in [CGFloat(112), 190, 240] {
                        let size = geometry.noticeSize(wingWidth: wing)
                        let wings = geometry.noticeWingWidth(preferred: wing)
                        suite.expect(size.height == geometry.stripHeight && size.height == geometry.cameraHeight
                               && geometry.frame(for: size).maxY == frame.maxY,
                               "feedback stays as tall as the camera cutout on physical and simulated notches")
                        suite.expect(wings > 0 && wings * 2 + geometry.noticeCameraGap == size.width,
                               "notice wings exactly fill their horizontal surface without entering the camera gap")
                        suite.expect(geometry.noticeCameraGap == geometry.cameraWidth,
                               "a simulated camera retains the same central gap as a physical camera")
                    }
                }
            }
        }
        let idle = roomy.restingSize(showsContent: false)
        suite.expect(NotchMotion.duration(from: idle, to: roomy.notice)
               == NotchMotion.duration(from: idle, to: roomy.expanded),
               "horizontal reveals use the opening curve even when their height stays unchanged")
        suite.expect(NotchMotion.duration(from: roomy.notice, to: idle)
               < NotchMotion.duration(from: idle, to: roomy.notice),
               "horizontal dismissal remains quicker than opening")
        // A level passing 99% or 9% keeps its notice and only fits the new width.
        for (from, to) in [(CGSize(width: 315, height: 33), CGSize(width: 329, height: 33)),
                           (CGSize(width: 315, height: 33), CGSize(width: 299, height: 33))] {
            let steady = NotchMotion.frames(from: from, to: to, steady: true)
            let widths = steady.sizes.map(\.width)
            let moving = zip(widths, widths.dropFirst()).allSatisfy { to.width > from.width ? $1 >= $0 : $1 <= $0 }
            suite.expect(moving && widths.allSatisfy { min(from.width, to.width) <= $0 && $0 <= max(from.width, to.width) }
                         && steady.sizes.last == to,
                         "a notice fitting a new reading eases to its width without swinging past it")
            let usual = NotchMotion.size(at: 0.1, from: from, to: to)
            let eased = NotchMotion.size(at: 0.1, from: from, to: to, steady: true)
            suite.expect(abs(eased.width - from.width) < abs(usual.width - from.width)
                         && steady.duration > NotchMotion.frames(from: from, to: to).duration,
                         "a notice fitting a new reading moves more gently than the island's springs")
        }
        // Equal total widths still move when the longer notice wing changes sides.
        let sameSize = CGSize(width: 380, height: 32)
        for start: CGFloat in [-120, 120] {
            let motion = NotchMotion.frames(from: sameSize, to: sameSize, offset: start)
            let offsets = motion.keyTimes.map {
                NotchMotion.offset(at: $0 * motion.duration, from: sameSize, to: sameSize, start: start)
            }
            suite.expect(motion.sizes.allSatisfy { $0 == sameSize }
                         && offsets.first == start && abs(offsets.last ?? .infinity) <= NotchMotion.settledDistance
                         && zip(offsets, offsets.dropFirst()).allSatisfy { abs($1) <= abs($0) }
                         && abs(NotchMotion.offset(at: 0.09, from: sameSize, to: sameSize, start: start)) < abs(start)
                         && motion.duration > 0.3,
                         "an equal-width notice moves its centre smoothly in either direction while its size stays put")
        }
        suite.expect(NotchMotion.offset(at: 0, from: sameSize, to: sameSize, start: 0) == 0,
                     "an unchanged notice with no shift stays in place")
        for (from, to) in [(CGSize(width: 315, height: 32), CGSize(width: 329, height: 32)),
                           (CGSize(width: 329, height: 32), CGSize(width: 315, height: 32))] {
            for steady in [false, true] {
                let time: TimeInterval = 0.09
                let size = NotchMotion.size(at: time, from: from, to: to, steady: steady)
                let expected = 60 * (1 - (size.width - from.width) / (to.width - from.width))
                suite.expect(abs(NotchMotion.offset(at: time, from: from, to: to, start: 60, steady: steady) - expected) < 0.001,
                             "a notice changing width still moves its centre with that same width spring")
            }
        }
        for (from, to) in [(roomy.collapsed, roomy.expanded), (idle, roomy.notice), (roomy.expanded, roomy.collapsed),
                           (roomy.notice, idle), (CGSize(width: roomy.collapsed.width, height: 0), roomy.peek),
                           (roomy.expanded, CGSize(width: roomy.collapsed.width, height: 0))] {
            let motion = NotchMotion.frames(from: from, to: to)
            let envelope = NotchMotion.envelope(from: from, to: to)
            let widest = motion.sizes.map(\.width).max() ?? 0
            let tallest = motion.sizes.map(\.height).max() ?? 0
            suite.expect(motion.sizes.first == from && motion.sizes.last == to
                   && motion.keyTimes.first == 0 && motion.keyTimes.last == 1 && motion.keyTimes.count == motion.sizes.count,
                   "the island's motion starts on screen and ends exactly at its target")
            suite.expect(widest <= envelope.width && tallest <= envelope.height,
                   "the reserved backing area holds every frame of the swing")
            suite.expect(envelope.width <= max(from.width, to.width) + NotchMotion.overshootLimit
                   && envelope.height <= max(from.height, to.height) + NotchMotion.overshootLimit,
                   "a long travel swings no farther than the room kept around the island")
            suite.expect(motion.duration > 0.1 && motion.duration < 0.6,
                   "the island settles within the time its surroundings wait for it: \(motion.duration)")
            suite.expect(motion.sizes.allSatisfy { $0.height >= 0 && $0.width >= 0 }, "no frame turns inside out")
            if to.width < from.width {
                suite.expect(motion.sizes.allSatisfy { $0.width >= to.width - 0.001 },
                       "a narrowing island never passes its resting width beside the camera")
            }
            if to.height < from.height {
                suite.expect(motion.sizes.allSatisfy { $0.height >= to.height - 0.001 },
                       "a shortening island never passes its resting height")
            }
            if to.width > from.width + 40 {
                suite.expect(widest > to.width, "a widening island stretches past its size before settling")
            }
            if to.height > from.height + 40 {
                suite.expect(tallest > to.height, "a lengthening island stretches past its size before settling")
            }
        }
        let long = NotchMotion.envelope(from: CGSize(width: 200, height: 32), to: CGSize(width: 1_400, height: 900))
        suite.expect(long.width <= 1_400 + NotchMotion.overshootLimit && long.height <= 900 + NotchMotion.overshootLimit
               && long.width > 1_400 && long.height > 900,
               "a long travel keeps its stretch within the room kept around the island")
        let drop = NotchMotion.frames(from: roomy.collapsed, to: roomy.expanded)
        let early = drop.sizes[drop.sizes.count / 8]
        suite.expect((early.height - roomy.collapsed.height) / (roomy.expanded.height - roomy.collapsed.height)
               > (early.width - roomy.collapsed.width) / (roomy.expanded.width - roomy.collapsed.width),
               "an opening island drops a little ahead of widening")
        let arrival = NotchMotion.arrivalTime(from: roomy.collapsed, to: roomy.expanded)
        let arrived = NotchMotion.size(at: arrival, from: roomy.collapsed, to: roomy.expanded)
        suite.expect(arrival > 0 && arrival < drop.duration
               && roomy.expanded.width - arrived.width <= (roomy.expanded.width - roomy.collapsed.width) * 0.01
               && roomy.expanded.height - arrived.height <= (roomy.expanded.height - roomy.collapsed.height) * 0.01,
               "floating controls emerge once the island reaches its size, before its swing settles")
        let horizontal = NotchMotion.frames(from: idle, to: roomy.notice)
        suite.expect(horizontal.sizes.allSatisfy { $0.height == idle.height },
               "horizontal feedback never swings below the menu bar")
        suite.expect(NotchMotion.envelope(from: roomy.expanded, to: roomy.expanded) == roomy.expanded,
               "an unchanged size reserves nothing more")
        for reserved in [CGSize(width: 571, height: 336), CGSize(width: 571.5, height: 40), CGSize(width: 300, height: 32)] {
            for size in [CGSize(width: 278, height: 32), CGSize(width: 277.5, height: 38), CGSize(width: 300, height: 32)] {
                let centred = NotchMotion.reservation(reserved, centring: size)
                let margin = (centred.width - size.width) / 2
                suite.expect(centred.width >= reserved.width && centred.height >= max(reserved.height, size.height)
                       && margin >= 0 && margin == margin.rounded(),
                       "a reserved window keeps whole, equal margins so the settled island does not shift a pixel")
            }
        }
        // An island opening toward one size can take a taller target on the
        // way, as content measured during the opening asks for.
        do {
            let field = CGSize(width: 616, height: roomy.collapsed.height + 76)
            let rows = CGSize(width: 616, height: 666)
            let opening = NotchMotionTimeline(from: roomy.collapsed, to: field, begin: 10)
            suite.expect((0...60).allSatisfy { step in
                             let time = Double(step) / 100
                             let size = opening.size(at: 10 + time)
                             let expected = NotchMotion.size(at: time, from: roomy.collapsed, to: field)
                             return abs(size.width - expected.width) < 0.001 && abs(size.height - expected.height) < 0.001
                         },
                         "a motion begun once moves exactly as the island's springs always have")
            let retarget = 10.07, frame = 1.0 / 60
            if let carried = opening.continued(to: rows, at: retarget) {
                let before = opening.size(at: retarget - frame), at = opening.size(at: retarget)
                let after = carried.size(at: retarget + frame)
                let restarted = NotchMotion.size(at: frame, from: at, to: rows)
                // What each side gained over the frame before the new target
                // and the frame after it, carried on or started again from rest.
                let widthBefore: CGFloat = at.width - before.width, widthAfter: CGFloat = after.width - at.width
                let heightBefore: CGFloat = at.height - before.height, heightAfter: CGFloat = after.height - at.height
                let restartedWidth: CGFloat = restarted.width - at.width, restartedHeight: CGFloat = restarted.height - at.height
                suite.expect(carried.start == at && carried.size(at: retarget) == at,
                             "a target moving on carries the island on from where it is")
                suite.expect(abs(widthAfter - widthBefore) < widthBefore / 4 && widthAfter > restartedWidth * 2,
                             "the width keeps its speed, where starting again from rest stalled it")
                suite.expect((0...50).allSatisfy {
                                 let time = retarget + Double($0) / 100
                                 return carried.size(at: time).width == opening.size(at: time).width
                             },
                             "a side whose target stays put keeps its own motion")
                suite.expect(heightAfter > restartedHeight + heightBefore / 2,
                             "a side whose target moves further keeps its speed as the new pull starts")
                let frames = carried.frames()
                suite.expect(frames.sizes.first == at && frames.sizes.last == rows && frames.keyTimes.first == 0
                             && frames.keyTimes.last == 1 && frames.keyTimes.count == frames.sizes.count,
                             "a carried motion starts on screen and ends exactly at its new target")
                suite.expect(frames.duration > 0.1 && frames.duration < 1,
                             "a carried motion settles within the time its surroundings wait for it: \(frames.duration)")
                let lowest = CGSize(width: at.width - 0.001, height: at.height - 0.001)
                let farthest = CGSize(width: rows.width + NotchMotion.overshootLimit, height: rows.height + NotchMotion.overshootLimit)
                suite.expect(frames.sizes.allSatisfy {
                                 $0.width >= lowest.width && $0.height >= lowest.height
                                     && $0.width <= farthest.width && $0.height <= farthest.height
                             },
                             "a carried motion never goes back and swings no farther than the room kept around the island")
            } else {
                suite.expect(false, "a taller target while opening carries the motion on")
            }
            suite.expect(opening.continued(to: roomy.collapsed, at: retarget) == nil
                         && opening.continued(to: CGSize(width: 616, height: field.height - 20), at: retarget) == nil,
                         "a motion turning back starts again from where it is drawn")
            suite.expect(NotchMotionTimeline(from: idle, to: roomy.notice, begin: 0, steady: true)
                             .continued(to: roomy.expanded, at: 0.05) == nil
                         && NotchMotionTimeline(from: idle, to: roomy.notice, begin: 0, offset: 40)
                             .continued(to: roomy.expanded, at: 0.05) == nil,
                         "a width easing without a swing, or a centre on its way, starts again as it always has")
            let late = opening.rebased(to: 10.02)
            suite.expect(late.begin == 10.02 && (0...40).allSatisfy { step in
                             let time = 10 + Double(step) / 100
                             let shifted = late.size(at: time + 0.02), original = opening.size(at: time)
                             return abs(shifted.width - original.width) < 0.001 && abs(shifted.height - original.height) < 0.001
                         },
                         "a motion that reached the screen late is timed from when it did")
        }
        func near(_ value: CGFloat, _ expected: CGFloat) -> Bool { abs(value - expected) < 0.000_1 }
        let closing = NotchGlassFade.plan(from: 200, to: 32, endsInGlass: false, current: 1)
        suite.expect(near(closing.openness(atHeight: 200), 0) && near(closing.openness(atHeight: 80), 0)
                && near(closing.openness(atHeight: 32), 0),
               "settled glass closing into a black strip shuts at once, since its page has already left")
        let opening = NotchGlassFade.plan(from: 32, to: 200, endsInGlass: true, current: 0)
        suite.expect(near(opening.openness(atHeight: 32), 0) && near(opening.openness(atHeight: 152), 0)
                && near(opening.openness(atHeight: 176), 0.5) && near(opening.openness(atHeight: 200), 1),
               "glass leaving a black strip stays shut until the last stretch, where its page fades in")
        let short = NotchGlassFade.plan(from: 32, to: 56, endsInGlass: true, current: 0)
        suite.expect(near(short.openness(atHeight: 32), 0) && near(short.openness(atHeight: 56), 1),
               "glass growing less than the stretch opens over its whole travel")
        let reopened = NotchGlassFade.plan(from: 56, to: 200, endsInGlass: true, current: 0.5)
        suite.expect(near(reopened.openness(atHeight: 56), 0.5) && near(reopened.openness(atHeight: 200), 1),
               "a close reversed halfway reopens from the openness on screen and ends fully open")
        let partlyOpen = opening.openness(atHeight: 180)
        let retargeted = NotchGlassFade.plan(from: 180, to: 220, endsInGlass: true, current: partlyOpen)
        suite.expect(near(retargeted.openness(atHeight: 180), partlyOpen)
               && near(retargeted.openness(atHeight: 220), 1),
               "a changed target keeps the glass already on screen and releases its black before settling")
        let reclosed = NotchGlassFade.plan(from: 180, to: 32, endsInGlass: false, current: 0.5)
        suite.expect(near(reclosed.openness(atHeight: 180), 0) && near(reclosed.openness(atHeight: 32), 0),
               "an opening reversed late shuts as its page leaves and ends black")
        suite.expect(NotchGlassFade.plan(from: 100, to: 300, endsInGlass: true, current: 1) == .open
                && NotchGlassFade.plan(from: 300, to: 100, endsInGlass: true, current: 1) == .open
                && NotchGlassFade.plan(from: .nan, to: 100, endsInGlass: false, current: 1) == .open,
               "glass resizing into glass, or an unreadable height, stays fully open")
        for available: CGFloat in [0, 27, 33, 43, 44, 45, 55, 64, 100, .nan, .infinity] {
            var tight = roomy
            tight.compactSideRoom = available
            let awake = tight.compactKeepAwakeGeometry()
            suite.expect(!awake.compactActivityUsesFooter && awake.compactActivitySize.height == roomy.menuBarHeight
                   && awake.compactActivityTopPadding == 0,
                   "a compact Keep Awake strip never grows or moves below the menu bar when space changes")
            suite.expect(awake.compactActivityWingWidth == 0
                   || awake.compactActivityWingWidth >= NotchKeepAwakeSupport.stripWingRange.lowerBound,
                   "the Keep Awake strip keeps whole wings beside the camera or none")
        }
        suite.expect(constrained.compactKeepAwakeGeometry().compactActivitySize.height == constrained.menuBarHeight,
               "a crowded activity strip retains the same thin silhouette")
        suite.expect(roomy.activityStrip.width <= 380 && roomy.restingWingWidth == 44,
               "activity strips and idle indicators both respect the same measured menu gap")
        let simulated = NotchGeometry(screen: menuScreen, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 22)
        suite.expect(simulated.frame(for: simulated.collapsed).maxY == menuScreen.maxY
               && simulated.cameraHeight == 22 && simulated.cameraWidth == 180 * 22.0 / 32,
               "a simulated cutout has notebook proportions and attaches directly to the screen edge")
        let crowdedRooms: [CGFloat?] = [nil, -1, 0, 27, 43, CGFloat.nan, CGFloat.infinity]
        for available in crowdedRooms {
            let crowded = NotchGeometry(screen: menuScreen, safeAreaTop: 32, cameraWidth: 180,
                                        menuBarHeight: 32, compactSideRoom: available)
            let size = crowded.compactActivitySize
            let window = crowded.frame(for: size)
            let visibleContentTop = window.maxY - crowded.compactActivityTopPadding
            suite.expect(crowded.compactActivityUsesFooter && crowded.compactActivityWingWidth >= 42,
                   "the footer fallback has readable content with missing or crowded menu geometry")
            suite.expect(size.width == crowded.cameraWidth && visibleContentTop <= menuScreen.maxY - crowded.cameraHeight,
                   "fallback content stays below the physical camera and its backing window never expands over adjacent menus")
            suite.expect(crowded.compactActivityWingWidth * 2 + crowded.compactActivityCameraGap
                   + crowded.compactActivityHorizontalPadding * 2 == size.width,
                   "both compact actions fit entirely in the fallback strip")
            suite.expect(menuScreen.contains(window) && window.maxY == menuScreen.maxY
                   && crowded.restingSize(showsContent: false).height == 32,
                   "a notched fallback keeps the physical top anchor and does not change quiet idle")
        }
        for available in [CGFloat(44), 80, 100, 180] {
            let lateral = NotchGeometry(screen: menuScreen, safeAreaTop: 32, cameraWidth: 180,
                                        menuBarHeight: 32, compactSideRoom: available)
            suite.expect(!lateral.compactActivityUsesFooter && lateral.compactActivitySize == lateral.activityStrip
                   && lateral.compactActivityCameraGap == lateral.cameraWidth
                   && lateral.compactActivityTopPadding == 0,
                   "confirmed lateral room retains the existing single-row presentation around the camera")
        }
        for frame in frames {
            let external = NotchGeometry(screen: frame, safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 22,
                                          compactSideRoom: nil)
            let position = external.frame(for: external.compactActivitySize)
            suite.expect(position.maxY == frame.maxY && frame.contains(position)
                   && external.compactActivityWingWidth == 0 && external.compactActivityTopPadding == 0,
                   "a simulated notch stays attached to its own screen edge in every coordinate quadrant")
        }
        suite.expect(NotchSupport.screenIndex(preference: .automatic, builtIn: [false, true],
                                       notched: [false, true], main: 0) == 1,
               "automatic uses the notched built-in screen even with external main display")
        suite.expect(NotchSupport.screenIndex(preference: .builtIn, builtIn: [false],
                                       notched: [false], main: 0) == nil,
               "closed-lid mode hides the island when the selected built-in display is unavailable")
        suite.expect(NotchSupport.screenIndex(preference: .automatic, builtIn: [false, false],
                                       notched: [false, false], main: 1) == 1
                     && NotchSupport.screenIndex(preference: .builtIn, builtIn: [false, false],
                                       notched: [false, false], main: 1) == nil,
               "external-only setups use the primary display automatically but hide a built-in-only island")
        suite.expect(NotchSupport.screenIndex(preference: .builtIn, builtIn: [false, true],
                                       notched: [false, true], main: 0) == 1,
               "the built-in choice returns to the laptop display when the lid opens")
        suite.expect(NotchSupport.screenIndex(preference: .builtIn, builtIn: [false, false],
                                       notched: [false, false], main: 1, hasLid: false) == 1
                     && NotchSupport.screenIndex(preference: .builtIn, builtIn: [true, false],
                                       notched: [false, false], main: 1, hasLid: false) == 0,
               "a Mac without a lid keeps the built-in choice on the main display, or on its own built-in panel")
        suite.expect(NotchSupport.screenIndex(preference: .main, builtIn: [], notched: [], main: 0) == nil,
               "no connected displays means no panel")
        suite.expect(NotchSupport.screenIndex(preference: .main, builtIn: [true, false, false],
                                       notched: [true, false, false], main: 2) == 2,
               "the main display choice follows the display with the menu bar, even beside a notched built-in screen")
        suite.expect(NotchSupport.screenIndex(preference: .pointer, builtIn: [true, false],
                                       notched: [true, false], main: 0, pointer: 1) == 1
                     && NotchSupport.screenIndex(preference: .pointer, builtIn: [true, false],
                                       notched: [true, false], main: 0, pointer: 0) == 0,
               "the pointer choice uses the display it follows, notched or not")
        suite.expect(NotchSupport.screenIndex(preference: .pointer, builtIn: [false, false],
                                       notched: [false, false], main: 1) == 1
                     && NotchSupport.screenIndex(preference: .pointer, builtIn: [false, false],
                                       notched: [false, false], main: 1, pointer: 2) == 1,
               "without a display to follow, the pointer choice keeps the main display")
        suite.expect(NotchSupport.screenIndex(preference: .pointer, builtIn: [false],
                                       notched: [false], main: 0, pointer: 0) == 0,
               "the pointer choice still shows the island in closed-lid mode")
        let layouts: [([Bool], [Bool], Int)] = [([true, false], [true, false], 0), ([false, false], [false, false], 1),
                                                ([false], [false], 0), ([true, false, false], [true, false, false], 2), ([], [], 0)]
        for (builtIn, notched, main) in layouts {
            for pointer in [nil, 0, 1, 2, 5] as [Int?] {
                suite.expect(NotchSupport.screenIndex(preference: .all, builtIn: builtIn, notched: notched, main: main,
                                                      pointer: pointer)
                             == NotchSupport.screenIndex(preference: .pointer, builtIn: builtIn, notched: notched, main: main,
                                                         pointer: pointer),
                             "with every display chosen, the island that responds follows the pointer")
            }
        }
        // The shape for displays without a notch shows only where the island can rest.
        suite.expect(!NotchSupport.reachesDisplayWithoutNotch(preference: .automatic, builtIn: [true, false],
                                                              notched: [true, false], main: 1),
               "automatic keeps a notched laptop's island off its monitor, even the main one")
        suite.expect(NotchSupport.reachesDisplayWithoutNotch(preference: .automatic, builtIn: [false],
                                                             notched: [false], main: 0),
               "automatic reaches the monitor once the lid closes")
        suite.expect(!NotchSupport.reachesDisplayWithoutNotch(preference: .builtIn, builtIn: [true, false],
                                                              notched: [true, false], main: 1),
               "the built-in choice keeps the island on its camera")
        suite.expect(!NotchSupport.reachesDisplayWithoutNotch(preference: .builtIn, builtIn: [false],
                                                              notched: [false], main: 0),
               "the built-in choice reaches no monitor while the lid is closed")
        suite.expect(NotchSupport.reachesDisplayWithoutNotch(preference: .builtIn, builtIn: [true, false],
                                                             notched: [false, false], main: 1),
               "a built-in screen without a notch floats the island itself")
        suite.expect(NotchSupport.reachesDisplayWithoutNotch(preference: .builtIn, builtIn: [false, false],
                                                             notched: [false, false], main: 1, hasLid: false),
               "a Mac without a lid keeps the built-in choice on its main display")
        suite.expect(NotchSupport.reachesDisplayWithoutNotch(preference: .main, builtIn: [true, false],
                                                             notched: [true, false], main: 1)
                     && !NotchSupport.reachesDisplayWithoutNotch(preference: .main, builtIn: [true, false],
                                                                 notched: [true, false], main: 0),
               "the main display choice reaches a monitor only when it has the menu bar")
        for preference in [NotchDisplay.pointer, .all] {
            suite.expect(NotchSupport.reachesDisplayWithoutNotch(preference: preference, builtIn: [true, false],
                                                                 notched: [true, false], main: 0),
                   "the pointer can take the island to a monitor: \(preference)")
            suite.expect(!NotchSupport.reachesDisplayWithoutNotch(preference: preference, builtIn: [true],
                                                                  notched: [true], main: 0),
                   "no display without a notch is reached when none is connected: \(preference)")
        }
        // Settings asks that rule with the displays connected now, and its
        // button switches to every display (issue #1711).
        let notchSettings = (try? String(contentsOfFile: "Sources/Brim/UI/Settings/NotchSettings.swift",
                                         encoding: .utf8)) ?? ""
        let notchServiceSource = (try? String(contentsOfFile: "Sources/Brim/Services/Notch/NotchService.swift",
                                              encoding: .utf8)) ?? ""
        suite.expect(notchSettings.contains("if enabled, !NotchService.reachesDisplayWithoutNotch(NotchDisplay(rawValue: display) ?? .automatic) {")
                     && notchSettings.contains("Button(text.showOnAllDisplays) { display = NotchDisplay.all.rawValue }")
                     && notchServiceSource.contains("NotchSupport.reachesDisplayWithoutNotch(preference: preference, builtIn: layout.builtIn,")
                     && notchServiceSource.contains("notched: layout.notched, main: layout.main, hasLid: hasLid)"),
               "the Displays without a notch card offers All displays only while the chosen display keeps the island off them")
        suite.expect(!NotchSupport.shouldReplace(.inputSource, with: .clipboard),
               "copy does not interrupt a keyboard layout change")
        suite.expect(NotchSupport.shouldReplace(.battery, with: .inputSource),
               "a keyboard layout change takes precedence over passive battery status")
        suite.expect((0..<9).map { NotchClipboardPastePress.index(
                    keyCode: [18, 19, 20, 21, 23, 22, 26, 28, 25][$0], commandOnly: true) } == (0..<9).map { $0 }
               && (0..<9).map { NotchClipboardPastePress.index(
                    keyCode: [83, 84, 85, 86, 87, 88, 89, 91, 92][$0], commandOnly: true) } == (0..<9).map { $0 }
               && NotchClipboardPastePress.index(keyCode: 18, commandOnly: false) == nil
               && NotchClipboardPastePress.index(keyCode: 29, commandOnly: true) == nil,
               "⌘1 to ⌘9 on the clipboard page name the first nine entries, and nothing else does")

        var session = NotchSessionState()
        session.locked = true
        session.sleeping = true
        session.sleeping = false
        suite.expect(!session.canPresent, "wake cannot reveal content over a locked screen")
        session.locked = false
        session.displaysSleeping = true
        suite.expect(!session.canPresent, "unlock alone cannot revive sleeping displays")
        session.displaysSleeping = false
        session.onConsole = false
        suite.expect(!session.canPresent, "another login session owns the display")
        session.onConsole = true
        suite.expect(session.canPresent, "presentation resumes after every privacy condition clears")
    }
}
