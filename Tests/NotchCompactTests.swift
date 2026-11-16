// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Production rail, editor, and focus bodies with inert services. Windows stay
/// hidden; these contracts neither capture pixels nor send input events.
enum NotchCompactTests {
    final class NotchService: ObservableObject {
        var presentationWindow: NSWindow?
        var contentSize = CGSize(width: 304, height: 122)
        var selected = NotchModule.controls
        var notice: NotchNotice?
        var showingSections = false
        var modules: [NotchModule] = [.controls, .clipboard]
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     safeAreaTop: 0, cameraWidth: 0, layout: .custom,
                                     menuBarHeight: 64, customWidth: 360, customHeight: 260)
        var expandedGeometry: NotchGeometry {
            var result = geometry
            result.pageTop = selected.pageTop
            return result
        }
    }
    struct NotchEmptyView: View {
        let symbol: String
        let message: String
        var body: some View { Text(message) }
    }
    struct NotchControlSurface: ViewModifier {
        let cornerRadius: CGFloat
        var interactive = true
        func body(content: Content) -> some View { content }
    }
    struct NotchButtonStyle: ButtonStyle {
        var cornerRadius: CGFloat = 10
        var lifts = true
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
    /// What each button the pages draw would do, by its title, so a test can press it.
    static var buttonActions: [String: () -> Void] = [:]
    struct NotchIconButton: View {
        let symbol: String
        let title: String
        var selected = false
        let action: () -> Void
        var body: some View {
            let _ = (NotchCompactTests.buttonActions[title] = action)
            Button(title, action: action)
        }
    }
    struct NotchPillButton: View {
        let title: String
        var prominent = false
        let action: () -> Void
        var body: some View {
            let _ = (NotchCompactTests.buttonActions[title] = action)
            Button(title, action: action)
        }
    }
    struct NotchMenuItem {
        let title: String
        var checked = false
        var symbol: String? = nil
        var enabled = true
        var action: () -> Void = {}
        static let separator = NotchMenuItem(title: "")
    }
    struct NotchMenuButton<Label: View>: View {
        let title: String
        let items: [NotchMenuItem]
        var cornerRadius: CGFloat = 6
        @ViewBuilder let label: () -> Label
        var body: some View { label() }
    }
    struct Page {
        var showsDetail = false
        var service = NotchService()
        var controls: [NotchControlItem] = [.keepAwake, .speedTest]
    }
    struct Entry: Identifiable { let id: Int }
    final class RailState: ObservableObject {
        @Published var selected: Int?
        @Published var rows = 2
        @Published var count = 1000
        @Published var width: CGFloat = 424
        @Published var leastSpacing: CGFloat?
        var realized = Set<Int>()
    }
    struct Marker: NSViewRepresentable {
        let id: Int
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier("rail-\(id)")
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
    struct Rail: View {
        @ObservedObject var state: RailState
        var body: some View {
            let entries = (0..<state.count).map { NotchCompactTests.Entry(id: $0) }
            return NotchRail(items: entries, rows: state.rows, itemWidth: 76, width: state.width,
                             leastSpacing: state.leastSpacing, scrollTarget: state.selected, content: marker)
                .frame(width: state.width, height: 152)
        }
        private func marker(_ item: NotchCompactTests.Entry) -> some View {
            state.realized.insert(item.id)
            return NotchCompactTests.Marker(id: item.id).frame(height: 72)
        }
    }

    static func settle(_ view: NSView? = nil) {
        for _ in 0..<30 {
            view?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    static func run(_ suite: TestSuite) {
        rail(suite)
        sizing(suite)
    }
    private static func rail(_ suite: TestSuite) {
        let state = RailState()
        let host = NSHostingView(rootView: Rail(state: state))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 424, height: 152),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 424, height: 152)
        settle(host)
        suite.expect(state.realized.count > 0 && state.realized.count < 40,
                     "a thousand history entries create only the visible rail neighborhood")
        let firstTiles = (0..<3).compactMap { id in
            descendants(host).first { $0.identifier?.rawValue == "rail-\(id)" }.map { $0.convert($0.bounds, to: host) }
        }
        if firstTiles.count == 3 {
            let gap = CGPoint(x: (firstTiles[0].maxX + firstTiles[2].minX) / 2, y: firstTiles[0].midY)
            var target = host.hitTest(gap)
            while let view = target, !(view is NSScrollView) { target = view.superview }
            suite.expect(target is NSScrollView,
                         "empty space between rail columns routes wheel events through the scroll view")
        } else {
            suite.expect(false, "the visible rail has enough columns to exercise its empty gap")
        }
        for (target, rows) in [(12, 2), (900, 2), (901, 2), (901, 1), (0, 1)] {
            state.rows = rows
            state.selected = target
            settle(host)
            let marker = descendants(host).first { $0.identifier?.rawValue == "rail-\(target)" }
            suite.expect(marker.map { host.bounds.intersects($0.convert($0.bounds, to: host)) } == true,
                         "selection \(target) remains visible after navigating or changing to \(rows) rail rows")
        }
        suite.expect(state.realized.count < 500,
                     "jumping to distant selections does not realize the intervening history")
        // Five tiles over two rows fit three columns wide: they read across
        // the rows, and the two on the last row sit centered under the three.
        state.count = 5
        state.rows = 2
        state.selected = nil
        settle(host)
        let frames = (0..<5).compactMap { id in
            descendants(host).first { $0.identifier?.rawValue == "rail-\(id)" }.map { $0.convert($0.bounds, to: host) }
        }
        suite.expect(frames.count == 5
               && frames[0].minY == frames[1].minY && frames[1].minY == frames[2].minY
               && frames[0].minX < frames[1].minX && frames[1].minX < frames[2].minX
               && frames[3].minY == frames[4].minY && frames[3].minY != frames[0].minY,
               "a rail that fits reads left to right along its rows")
        suite.expect(frames.count == 5
               && abs(frames[3].width - frames[0].width) < 0.5
               && abs(frames[3].midX - (frames[0].midX + frames[1].midX) / 2) < 0.5
               && abs((frames[3].minX + frames[4].maxX) / 2 - host.bounds.midX) < 0.5,
               "a short last row keeps the cell width and sits centered under the row above")
        // Four tiles in one row just miss the narrowest page with their gaps.
        // A rail that may close them keeps every tile whole, side by side;
        // any other still scrolls its last column past the edge.
        state.count = 4
        state.rows = 1
        state.width = 304
        host.frame = NSRect(x: 0, y: 0, width: 304, height: 152)
        for least in [NotchLayout.shortcutLeastSpacing, nil] {
            state.leastSpacing = least
            settle(host)
            let tiles = (0..<4).compactMap { id in
                descendants(host).first { $0.identifier?.rawValue == "rail-\(id)" }.map { $0.convert($0.bounds, to: host) }
            }
            let whole = tiles.count == 4 && tiles.allSatisfy { (tile: CGRect) -> Bool in
                tile.minX >= -0.5 && tile.maxX <= 304.5 && abs(tile.width - 76) < 0.5
            }
            suite.expect(whole == (least != nil), least != nil
                         ? "a rail that closes its gaps keeps four tiles whole across the narrowest page"
                         : "a rail with no least gap still scrolls the column that misses its width")
        }
    }
    private static func sizing(_ suite: TestSuite) {
        var page = Page()
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for bar: CGFloat in [24, 32, 40, 48, 64] {
            let geometry = NotchGeometry(screen: screen, safeAreaTop: 0, cameraWidth: 0, layout: .custom,
                                         menuBarHeight: bar, customWidth: 360, customHeight: 260)
            for module in [NotchModule.controls, .clipboard] {
                page.service.selected = module
                page.service.contentSize = geometry.contentSize(for: geometry.expandedSize(module: module))
                let layout = page.pageSize
                suite.expect(layout.width == page.service.contentSize.width
                             && layout.height >= page.service.contentSize.height,
                             "\(module) keeps the chosen width and exposes any vertically overflowing content")
                if module == .controls {
                    let required = NotchLayout.controls(shortcutCount: page.controls.count,
                                                        width: layout.width, height: layout.height)
                    suite.expect(required.height <= layout.height, "home buttons fit their scrollable layout at menu height \(bar)")
                } else if module == .clipboard {
                    suite.expect(layout.height >= NotchLayout.clipboardCardHeight,
                                 "a short clipboard page keeps a complete card reachable")
                }
            }
        }
        page.controls = [.keepAwake]
        page.service.selected = .controls
        page.service.contentSize = CGSize(width: 424, height: 96)
        suite.expect(page.pageSize == page.service.contentSize, "a single home card does not introduce unnecessary scrolling")
        page.showsDetail = true
        suite.expect(page.pageSize == page.service.contentSize, "vertical detail pages preserve their existing layout")
    }
}

/// The island's top row as the pages use it. The row itself is not part of
/// these tests, so a page's items are drawn above it, built from the page's
/// state as the island builds them.
private struct NotchCompactBandKey: EnvironmentKey {
    static let defaultValue = NotchBand()
}

extension EnvironmentValues {
    var notchBand: NotchBand {
        get { self[NotchCompactBandKey.self] }
        set { self[NotchCompactBandKey.self] = newValue }
    }
}

extension View {
    func notchBand<Leading: View, Trailing: View>(@ViewBuilder leading: () -> Leading,
                                                  @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack { leading(); trailing() }
            self
        }
    }
}

/// A menu's label in the row, as the island draws it.
struct NotchBandMenuLabel: View {
    let title: String
    var symbol: String? = nil
    var truncation: Text.TruncationMode = .tail

    var body: some View { Text(title).lineLimit(1).truncationMode(truncation) }
}
