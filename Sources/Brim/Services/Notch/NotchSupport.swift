// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Foundation
import CoreGraphics

enum NotchModule: String, CaseIterable, Identifiable {
    case controls, clipboard, system, agents
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .controls: return "slider.horizontal.3"
        case .clipboard: return "doc.on.clipboard"
        case .system: return "gauge.with.dots.needle.50percent"
        case .agents: return "sparkles"
        }
    }

    /// Stable across ordering and languages; every destination has a direct key.
    var shortcutKey: String {
        switch self {
        case .controls: return "c"
        case .clipboard: return "b"
        case .system: return "i"
        case .agents: return "g"
        }
    }

    func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .controls: return true
        case .clipboard: return AppFeature.clipboardHistory.isAvailable(in: defaults)
        case .agents: return AppFeature.notchAgents.isAvailable(in: defaults)
        case .system:
            return [.monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork,
                    .monitorDisk, .monitorPower, .fanControl, .connectedDevices].contains { (feature: AppFeature) in
                feature.isAvailable(in: defaults)
            }
        }
    }
}

enum NotchReopeningDestination: String, CaseIterable {
    case appPanel, explore
}

/// ⌘1 to ⌘9 on the island's clipboard page paste the entry at that place in
/// the visible list, as in the quick panel.
struct NotchClipboardPastePress: Equatable {
    let serial: Int
    let index: Int

    /// The digit row by physical key, so every layout keeps the shortcut,
    /// and the numeric keypad's digits.
    static func index(keyCode: UInt16, commandOnly: Bool) -> Int? {
        guard commandOnly else { return nil }
        let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keypadKeys: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        return digitKeys.firstIndex(of: keyCode) ?? keypadKeys.firstIndex(of: keyCode)
    }
}

enum NotchDisplay: String, CaseIterable {
    /// `pointer` moves the closed island to the display the pointer is on.
    /// `all` does too, and every other display shows the closed island.
    case automatic, builtIn, main, pointer, all
}

/// How the island meets the top of a display without a camera housing: a
/// capsule floating in the menu bar, as on the phone, or a cutout hanging
/// from the top edge. A physical camera always keeps the cutout it covers.
enum NotchSilhouette: String, CaseIterable {
    case capsule, notch

    static func current(in defaults: UserDefaults = .standard) -> NotchSilhouette {
        NotchSilhouette(rawValue: defaults.string(forKey: DefaultsKey.notchSilhouette) ?? "") ?? .capsule
    }
}

enum NotchSize: String, CaseIterable {
    case compact, spacious, custom

    static let widthRange = 360.0...600.0
    static let heightRange = 260.0...640.0
    static let defaultWidth = 440.0
    static let defaultHeight = 480.0

    static func clamped(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// A correction to the camera housing macOS reports. The report is rounded
/// to points while the cutout follows the panel's own pixels, so on some Macs
/// and resolutions an edge of the real notch can show past the island.
struct NotchCameraFit: Equatable {
    static let widthRange = -10.0...10.0
    static let heightRange = -6.0...6.0
    static let zero = NotchCameraFit(width: 0, height: 0)

    let width: CGFloat
    let height: CGFloat

    /// Whole points keep the island centred on the camera's pixels, and half
    /// points are whole pixels on the notched panels; a value written by hand
    /// is brought back to those steps.
    init(width: Double, height: Double) {
        self.width = NotchSize.clamped(width, to: Self.widthRange, fallback: 0).rounded()
        self.height = (NotchSize.clamped(height, to: Self.heightRange, fallback: 0) * 2).rounded() / 2
    }

    static func current(in defaults: UserDefaults = .standard) -> NotchCameraFit {
        NotchCameraFit(width: defaults.double(forKey: DefaultsKey.notchCameraFitWidth),
                       height: defaults.double(forKey: DefaultsKey.notchCameraFitHeight))
    }
}

/// A capsule sized and placed by hand. By itself it takes the height of the
/// menu bar around it; a fit makes it wider or narrower at rest, taller or
/// shorter from its top edge, and lowers it from the top of the display.
/// Width and height reach as far each way, so an untouched slider rests in
/// the middle, as the camera fit's do.
struct NotchCapsuleFit: Equatable {
    static let widthRange = -40.0...40.0
    static let heightRange = -4.0...4.0
    static let dropRange = 0.0...20.0
    static let zero = NotchCapsuleFit(width: 0, height: 0, drop: 0)

    let width: CGFloat
    let height: CGFloat
    let drop: CGFloat

    /// Whole points keep the capsule's edges on pixels, and even widths keep
    /// it centred; a value written by hand is brought back to those steps.
    init(width: Double, height: Double, drop: Double) {
        self.width = (NotchSize.clamped(width, to: Self.widthRange, fallback: 0) / 2).rounded() * 2
        self.height = NotchSize.clamped(height, to: Self.heightRange, fallback: 0).rounded()
        self.drop = NotchSize.clamped(drop, to: Self.dropRange, fallback: 0).rounded()
    }

    static func current(in defaults: UserDefaults = .standard) -> NotchCapsuleFit {
        NotchCapsuleFit(width: defaults.double(forKey: DefaultsKey.notchCapsuleFitWidth),
                        height: defaults.double(forKey: DefaultsKey.notchCapsuleFitHeight),
                        drop: defaults.double(forKey: DefaultsKey.notchCapsuleFitDrop))
    }
}

/// How an open page uses the island's top row. The island names no page:
/// the row holds the page's own controls, beside a physical camera when
/// they fit there, as a phone's island wraps its camera.
enum NotchPageTop: Equatable {
    /// Its controls on either side of the camera, or its first row.
    case row
    /// Nothing of its own for the row: beside a camera the row holds only
    /// the island's own buttons, and elsewhere the page starts at the top
    /// unless the row has to lead to the sections.
    case none
}

extension NotchModule {
    var pageTop: NotchPageTop { self == .system ? .none : .row }
}

/// The open island's top row as a page lays out its controls in it.
struct NotchBand: Equatable {
    /// Room every control keeps from the camera.
    static let cameraClearance: CGFloat = 8
    /// The island's way to its sections: a 28-point button and the row's
    /// spacing after it.
    static let sectionsButtonRoom: CGFloat = 28 + 6

    /// The row wraps a physical camera, half of it on either side.
    var besideCamera = false
    var height: CGFloat = NotchLayout.headerHeight
    /// Each side's width beside the camera, past the clearance; without a
    /// camera, the whole row.
    var side: CGFloat = 0
    /// The island's way to its sections leads the row, before the page's
    /// own controls.
    var sectionsButton = false

    init() {}

    init(geometry: NotchGeometry, contentWidth: CGFloat) {
        besideCamera = geometry.headerCameraGap > 0
        height = geometry.headerRowHeight
        side = besideCamera
            ? max(0, (contentWidth - geometry.headerCameraGap) / 2 - Self.cameraClearance) : max(0, contentWidth)
        sectionsButton = geometry.sectionsButtonInRow
    }
}

/// Shared measurements keep the window's content budget and its SwiftUI
/// layout in agreement, including small screens and custom sizes.
enum NotchLayout {
    static let shoulder: CGFloat = 14
    static let horizontalInset: CGFloat = 28
    static let headerHeight: CGFloat = 36
    static let navigationHeight: CGFloat = 36
    static let spacing: CGFloat = 12
    static let bottomInset: CGFloat = 16
    /// The island stays a wide strip: pages scroll within the preset's budget.
    static let compactContentHeight: CGFloat = 180
    static let spaciousContentHeight: CGFloat = 264
    /// Surfaces that are vertical by nature (the embedded app panel, a metric
    /// detail, a hosted utility) still get a readable page inside a preset.
    static let pageContentHeight: CGFloat = 320
    static let rowSpacing: CGFloat = 10
    static let shortcutHeight: CGFloat = 74
    static let shortcutWidth: CGFloat = 76
    static let shortcutSpacing: CGFloat = 8
    /// Tiles that would just miss the island's width close their gaps, down
    /// to none, before their rail scrolls: each tile's own margin keeps them
    /// apart, and the narrowest island holds four across.
    static let shortcutLeastSpacing: CGFloat = 0
    /// A rail a few points short of its next row closes its rows only this
    /// far: a title on two lines then sits as near the circle under it as
    /// its own circle above, never nearer.
    static let shortcutLeastRowSpacing: CGFloat = 6
    static let systemCardHeight: CGFloat = 72
    static let systemCardWidth: CGFloat = 128
    /// Leave room for the card's hover scale, including a single full-width card.
    static func systemHoverInset(width: CGFloat) -> CGFloat { ceil(max(0, width) * 0.015) + 1 }
    /// Three rows fit the gallery's page; two still fill a compact strip.
    static let sectionTileHeight: CGFloat = 86
    static let sectionTileWidth: CGFloat = 92
    static let sectionSpacing: CGFloat = 8
    /// The gallery's row indicator beside the tiles, with its gap.
    static let sectionIndicatorWidth: CGFloat = 12
    /// The search field the clipboard page shows once it is wanted.
    static let clipboardSearchHeight: CGFloat = 36
    static let clipboardCardHeight: CGFloat = 104
    /// One or two lines of the entry, until the pointer rests on it.
    static let clipboardCompactCardHeight: CGFloat = 52
    static let clipboardCardSpacing: CGFloat = 8
    static let emptyHeight: CGFloat = 140
    /// The home page is never narrower than this, however few its shortcuts.
    static let homeContentWidth: CGFloat = 344

    /// Breathing room every compact strip keeps from its silhouette.
    static let compactEdgeGap: CGFloat = 5
    /// Corners of a surface of this height. A strip as tall as the camera
    /// keeps the cutout's own corners, so the closed island and the last
    /// frames of a collapse sit inside the notch instead of outlining a
    /// rounder one; the open island reaches the full radius and shoulder.
    static func surfaceRadius(height: CGFloat) -> CGFloat { min(28, height * 0.34) }
    static func shoulder(height: CGFloat) -> CGFloat { min(shoulder, height * 0.19) }
    /// The optional outline's stroke. Only its inner half, inside the island, shows.
    static let outlineWidth: CGFloat = 2

    // MARK: Capsule
    // Without a camera the island can float in the menu bar as a capsule.
    // Open, it keeps the hanging island's sizes, so its window, hover, pages
    // and floating controls stay where they are. Closed, its strips run from
    // end to end, as NotchCapsuleLayout measures them.

    /// The menu bar a capsule leaves above and below itself on a standard bar.
    static let capsuleMargin: CGFloat = 2

    /// A shorter bar leaves less, so the capsule is 20 points tall on a
    /// standard bar and on a display whose bar is hidden.
    static func capsuleGap(barHeight: CGFloat) -> CGFloat {
        guard barHeight.isFinite else { return 0 }
        return min(capsuleMargin, max(0, ((barHeight - 20) / 2).rounded(.down)))
    }

    /// A closed capsule is round at its ends; an open one keeps the island's corners.
    static func capsuleRadius(height: CGFloat) -> CGFloat { min(max(0, height) / 2, 28) }

    /// The bare capsule at rest is shorter than the gap between an
    /// activity's wings, closer to the phone's proportions.
    static let capsuleRestingAspect: CGFloat = 5

    /// The capsule of a surface `rect` in size: `gap` inside its top and
    /// bottom, and as wide as the hanging island's body between its
    /// shoulders, which content and floating controls are laid out around.
    static func capsuleBody(in rect: CGRect, gap: CGFloat) -> CGRect {
        let width = max(0, rect.width), height = max(0, rect.height)
        let side = min(shoulder(height: height), width / 2)
        let inset = min(max(0, gap), height / 2)
        return CGRect(x: rect.minX + side, y: rect.minY + inset,
                      width: width - side * 2, height: height - inset * 2)
    }

    /// The surface a capsule was drawn for, from the bounds it was drawn in,
    /// so a resize starts from the size on screen.
    static func capsuleSurface(ofBody body: CGRect, gap: CGFloat) -> CGSize {
        let height = body.height > 0 ? body.maxY + max(0, gap) : body.minY * 2
        return CGSize(width: body.width + shoulder(height: height) * 2, height: max(0, height))
    }

    /// The capsule outline. Every size, down to a line, has the same elements,
    /// so any two frames of a resize blend, and circular corners make a
    /// strip's ends true half circles that its content can be measured from.
    static func capsulePath(in rect: CGRect, gap: CGFloat) -> CGPath {
        let body = capsuleBody(in: rect, gap: gap)
        let corner = min(capsuleRadius(height: body.height), body.width / 2)
        let handle = corner * (1 - 0.55228475)
        let (left, right, top, bottom) = (body.minX, body.maxX, body.minY, body.maxY)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left + corner, y: top))
        path.addLine(to: CGPoint(x: right - corner, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + corner), control1: CGPoint(x: right - handle, y: top),
                      control2: CGPoint(x: right, y: top + handle))
        path.addLine(to: CGPoint(x: right, y: bottom - corner))
        path.addCurve(to: CGPoint(x: right - corner, y: bottom), control1: CGPoint(x: right, y: bottom - handle),
                      control2: CGPoint(x: right - handle, y: bottom))
        path.addLine(to: CGPoint(x: left + corner, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - corner), control1: CGPoint(x: left + handle, y: bottom),
                      control2: CGPoint(x: left, y: bottom - handle))
        path.addLine(to: CGPoint(x: left, y: top + corner))
        path.addCurve(to: CGPoint(x: left + corner, y: top), control1: CGPoint(x: left, y: top + handle),
                      control2: CGPoint(x: left + handle, y: top))
        path.closeSubpath()
        return path
    }

    static func preferredWidth(_ layout: NotchSize, custom: CGFloat) -> CGFloat {
        switch layout {
        case .compact: return 480
        case .spacious: return 560
        case .custom: return custom
        }
    }

    /// Balance complete rows across the available width, keeping reading order
    /// left to right and allowing each row to fill its width without empty cells.
    static func systemRowRanges(count: Int, width: CGFloat) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let columns = railCapacity(width: width, itemWidth: systemCardWidth, spacing: rowSpacing)
        let rows = (count + columns - 1) / columns
        let base = count / rows
        let remainder = count % rows
        return (0..<rows).map { row in
            let start = row * base + min(row, remainder)
            return start..<(start + base + (row < remainder ? 1 : 0))
        }
    }

    // MARK: Rails
    // Items fill the rows a height allows and continue sideways. Every page
    // and the geometry that sizes it share these three functions, so the
    // window never reserves a row the page cannot draw.

    static func railCapacity(width: CGFloat, itemWidth: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, itemWidth > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (itemWidth + spacing)).rounded(.down)))
    }

    static func railRows(count: Int, perRow: Int, rowHeight: CGFloat, spacing: CGFloat, height: CGFloat) -> Int {
        let capacity = max(1, perRow)
        let needed = max(1, (max(0, count) + capacity - 1) / capacity)
        guard rowHeight > 0 else { return 1 }
        guard height.isFinite else { return height > 0 ? needed : 1 }
        let fitting = max(1, Int(((height + spacing) / (rowHeight + spacing)).rounded(.down)))
        return min(needed, fitting)
    }

    static func railHeight(rows: Int, rowHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        CGFloat(max(1, rows)) * rowHeight + CGFloat(max(0, rows - 1)) * spacing
    }

    /// The columns a rail spreads its items over. A rail whose columns all
    /// fit lays the items out in reading order, this many per row, and
    /// centers a short last row; one that scrolls fills its columns instead.
    static func railColumns(count: Int, rows: Int) -> Int {
        (max(0, count) + max(1, rows) - 1) / max(1, rows)
    }

    static func railFits(columns: Int, itemWidth: CGFloat, spacing: CGFloat, width: CGFloat) -> Bool {
        CGFloat(columns) * itemWidth + CGFloat(max(0, columns - 1)) * spacing <= width
    }

    /// The room between the columns of a rail that fits: its own spacing,
    /// or what is left where that would just miss the width, down to
    /// `least`, so the rail closes its gaps before it scrolls. Nil once
    /// the columns would not fit even then.
    static func railGap(columns: Int, itemWidth: CGFloat, spacing: CGFloat, least: CGFloat, width: CGFloat) -> CGFloat? {
        if railFits(columns: columns, itemWidth: itemWidth, spacing: spacing, width: width) { return spacing }
        guard columns > 1, railFits(columns: columns, itemWidth: itemWidth, spacing: least, width: width) else { return nil }
        return (width - CGFloat(columns) * itemWidth) / CGFloat(columns - 1)
    }

    /// The content width a page reads best at, short of the width the island
    /// may take (`width`): the home page is as wide as its one row of
    /// shortcuts. Lists, grids and a rail that wraps take it all (nil).
    static func naturalContentWidth(_ module: NotchModule, controls: [NotchControlItem], within width: CGFloat) -> CGFloat? {
        guard module == .controls else { return nil }
        let shortcuts = controls.count
        guard shortcuts <= railCapacity(width: width, itemWidth: shortcutWidth, spacing: shortcutSpacing) else { return nil }
        let rail = CGFloat(shortcuts) * (shortcutWidth + shortcutSpacing) - (shortcuts > 0 ? shortcutSpacing : 0)
        return max(rail, homeContentWidth)
    }

    /// The home page: a rail of shortcuts. A tight budget closes the rows of
    /// a rail that would scroll before it drops a row.
    static func controls(shortcutCount: Int, width: CGFloat, height: CGFloat) -> NotchControlsLayout {
        guard shortcutCount > 0 else { return NotchControlsLayout(shortcutRows: 0) }
        var rows = railRows(count: shortcutCount,
                            perRow: railCapacity(width: width, itemWidth: shortcutWidth, spacing: shortcutSpacing),
                            rowHeight: shortcutHeight, spacing: shortcutSpacing, height: height)
        var rowGap = shortcutSpacing
        // A rail that would scroll sideways closes its rows as it closes
        // its columns, to take the row it is a few points short of; one
        // that fits keeps its rows and gaps.
        if railGap(columns: railColumns(count: shortcutCount, rows: rows), itemWidth: shortcutWidth,
                   spacing: shortcutSpacing, least: shortcutLeastSpacing, width: width) == nil,
           let gap = railGap(columns: rows + 1, itemWidth: shortcutHeight, spacing: shortcutSpacing,
                             least: shortcutLeastRowSpacing, width: height) {
            rows += 1
            rowGap = gap
        }
        return NotchControlsLayout(shortcutRows: rows, shortcutRowSpacing: rowGap)
    }

}

enum NotchClipboardKey: Equatable {
    case move(backwards: Bool)
    case paste
    /// The key goes on to the search field, which shows to take it.
    case reveal
}

struct NotchControlsLayout: Equatable {
    let shortcutRows: Int
    var shortcutRowSpacing = NotchLayout.shortcutSpacing

    var height: CGFloat {
        shortcutRows > 0
            ? NotchLayout.railHeight(rows: shortcutRows, rowHeight: NotchLayout.shortcutHeight, spacing: shortcutRowSpacing) : 0
    }
}

enum NotchIdleContent: String, CaseIterable {
    case none, battery, agents
}

/// How urgently the charge is shown: amber for the early warning, red when low.
enum BatteryWarning: Equatable {
    case none, early, low
}

/// Resizing can send hover exits and entries without any pointer movement.
struct NotchHoverState {
    private(set) var suppressed = false

    mutating func close(pointerInside: Bool) { suppressed = pointerInside }
    mutating func open() { suppressed = false }
    mutating func update(pointerInside: Bool) {
        if !pointerInside { suppressed = false }
    }
}

enum NotchHoverEmphasis {
    static func size(from resting: CGSize, geometry: NotchGeometry) -> CGSize {
        // Keep the pulse inside the measured free menu-bar space on each side.
        let occupiedWing = max(0, (resting.width - geometry.cameraWidth) / 2)
        let freeSide = max(0, (geometry.compactSideRoom ?? 0) - occupiedWing)
        let growth = min(10, freeSide)
        // A capsule stretches along the bar and stays inside it.
        return CGSize(width: resting.width + growth * 2, height: resting.height + (geometry.floats ? 0 : 5))
    }
}

enum NotchCompactActivity: String, Identifiable {
    case agents, keepAwake

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .agents: return FeatureStrings.notchAgents(language).title
        case .keepAwake: return Strings.localized(language).keepAwakeTitle
        }
    }

    /// Keep Awake has no page of its own: its tile is on Controls.
    var module: NotchModule {
        switch self {
        case .agents: return .agents
        case .keepAwake: return .controls
        }
    }

    var symbol: String {
        self == .keepAwake ? NotchControlItem.keepAwake.symbol : module.symbol
    }
}

/// The closed island on a display it is not on, when it shows on every
/// display: that display's geometry, and what the island shows closed at
/// the size it takes there. The service updates it as the island changes.
final class NotchMirrorModel: ObservableObject {
    @Published private(set) var geometry: NotchGeometry
    /// A strip beside a camera has its own geometry around it, as the island's does.
    @Published private(set) var strip: NotchGeometry
    @Published private(set) var size: CGSize
    @Published private(set) var activity: NotchCompactActivity?
    var shown = false
    /// The outline last drawn around it.
    var outline: Bool?

    init(geometry: NotchGeometry, size: CGSize) {
        self.geometry = geometry
        strip = geometry
        self.size = size
    }

    /// Whether anything it draws changed, so a copy is only resized when it did.
    func update(geometry: NotchGeometry, strip: NotchGeometry, size: CGSize, activity: NotchCompactActivity?) -> Bool {
        guard self.geometry != geometry || self.strip != strip || self.size != size || self.activity != activity else {
            return false
        }
        self.geometry = geometry
        self.strip = strip
        self.size = size
        self.activity = activity
        return true
    }
}

/// A choice outlives the gaps in what was chosen, such as an agent between
/// turns: the island shows the next activity meanwhile and returns to the
/// chosen one. It ends when nothing is left to show, so work returning later
/// starts from the automatic order again.
struct NotchActivitySelection {
    private(set) var preferred: NotchCompactActivity?

    mutating func select(_ activity: NotchCompactActivity, available: [NotchCompactActivity]) {
        guard available.contains(activity) else { return }
        preferred = activity
    }

    mutating func reconcile(available: [NotchCompactActivity]) {
        guard available.isEmpty else { return }
        preferred = nil
    }

    func current(available: [NotchCompactActivity]) -> NotchCompactActivity? {
        if let preferred, available.contains(preferred) { return preferred }
        return available.first
    }
}

/// A floating capsule has no camera inside it, so its closed content runs in
/// one row from end to end, and the capsule is as wide as that row needs:
/// never shorter than the bare capsule, never wider than its kind allows or
/// than the menu bar leaves free. The views draw with these same measures.
enum NotchCapsuleLayout {
    /// From the capsule's round end to its first and last content.
    static let endPadding: CGFloat = 8
    /// Between a mark and its text.
    static let spacing: CGFloat = 6
    /// Between a title and its detail, or between two groups.
    static let groupSpacing: CGFloat = 10
    /// A symbol's slot, as wide as the widest symbol draws at its size.
    static let symbolSize: CGFloat = 12
    static let symbolWidth: CGFloat = 16
    /// SwiftUI can draw a line a little wider than AppKit measures it.
    static let air: CGFloat = 2
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let readingFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    /// The widest each kind of strip grows, in points of capsule.
    enum Maximum {
        static let notice: CGFloat = 340
        static let activity: CGFloat = 220
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + air
    }

    private static var symbolDrops: [String: CGFloat] = [:]

    /// How far a symbol's ink sits below the middle of its frame. SF Symbols
    /// hang low in their frames, a circle almost half a point, so centred by
    /// frame a timer looked a pixel low beside its centred digits. Measured
    /// once per symbol, from its own drawing.
    static func symbolDrop(_ name: String, size: CGFloat = symbolSize, weight: NSFont.Weight = .medium) -> CGFloat {
        let key = "\(name) \(size) \(weight.rawValue)"
        if let drop = symbolDrops[key] { return drop }
        let drop = measuredSymbolDrop(name, size: size, weight: weight)
        symbolDrops[key] = drop
        return drop
    }

    private static func measuredSymbolDrop(_ name: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let scale: CGFloat = 4
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)),
              image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((image.size.width * scale).rounded(.up)),
                                         pixelsHigh: Int((image.size.height * scale).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return 0 }
        // In points before the context exists, so the drawing fills the pixels.
        rep.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return 0 }
        // Rows run from the top; a pixel counts once it is about a third inked.
        var top: Int?, bottom = 0
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            if (0..<rep.pixelsWide).contains(where: { row[$0 * 4 + 3] > 80 }) { top = top ?? y; bottom = y + 1 }
        }
        guard let top else { return 0 }
        return CGFloat(top + bottom) / 2 / scale - image.size.height / 2
    }

    /// The capsule's side within its surface, as `capsuleBody` places it.
    static func side(_ geometry: NotchGeometry) -> CGFloat { NotchLayout.shoulder(height: geometry.stripHeight) }

    /// The widest surface the bar leaves: the display less its margins, and
    /// the menus' free space on both sides of the capsule's middle.
    static func availableWidth(_ geometry: NotchGeometry) -> CGFloat {
        let room = geometry.compactSideRoom ?? 0
        return max(0, min(geometry.screen.width - 24, geometry.cameraWidth + 2 * (room.isFinite ? max(0, room) : 0)))
    }

    /// The surface around a row `content` wide between `leading` and
    /// `trailing` insets from the capsule's ends, on whole points like the
    /// window around it.
    static func surface(content: CGFloat, leading: CGFloat = endPadding, trailing: CGFloat = endPadding,
                        maximum: CGFloat, geometry: NotchGeometry) -> CGSize {
        let side = side(geometry)
        let resting = geometry.restingSize(showsContent: false).width
        let limit = max(resting, min(maximum + side * 2, availableWidth(geometry)).rounded(.down))
        let wanted = (max(0, content.isFinite ? content : 0) + leading + trailing + side * 2).rounded(.up)
        return CGSize(width: min(limit, max(resting, wanted)), height: geometry.stripHeight)
    }

    /// Two working agents share a smaller mark, each in a frame wider than it.
    static func agentMarkSize(working: Int) -> CGFloat { working > 1 ? 10 : 12 }
    static func agentMarksWidth(working: Int) -> CGFloat {
        let count = max(1, working)
        return CGFloat(count) * (agentMarkSize(working: count) * 1.45 + 1) + CGFloat(count - 1)
    }

    /// The row a notice reads in: its mark, its title and its detail.
    static func noticeContent(title: String, detail: String) -> CGFloat {
        let detailWidth = width(detail, font: detailFont)
        return symbolWidth + spacing + width(title, font: titleFont) + (detailWidth > 0 ? groupSpacing + detailWidth : 0)
    }

    /// A Keep Awake session: the cup, wider than other marks, then the time
    /// it has left measured by its shape, or infinity for a session without
    /// an end.
    static func keepAwakeSurface(reading: String?, geometry: NotchGeometry) -> CGSize {
        let cup = NotchKeepAwakeSupport.symbolWidth(NotchKeepAwakeSupport.symbol, size: symbolSize)
        let right = reading.map { width(NotchAgentSupport.readingShape($0), font: readingFont) }
            ?? NotchKeepAwakeSupport.symbolWidth(NotchKeepAwakeSupport.openSymbol, size: readingFont.pointSize) + air
        return surface(content: cup + spacing + right, maximum: Maximum.activity, geometry: geometry)
    }

    /// Working agents' marks and the reading the person chose.
    static func agentSurface(reading: String, working: Int, geometry: NotchGeometry) -> CGSize {
        let content = agentMarksWidth(working: working) + spacing
            + width(NotchAgentSupport.readingShape(reading), font: readingFont)
        return surface(content: content, maximum: Maximum.activity, geometry: geometry)
    }

}

struct NotchActivityPickerLayout {
    static let rowHeight: CGFloat = 32
    static let spacing: CGFloat = 6
    static let horizontalInset: CGFloat = 24
    static let verticalInset: CGFloat = 12
    let columns: Int
    let headerHeight: CGFloat
    let size: CGSize

    init(count: Int, labelWidth: CGFloat, stripSize: CGSize, screenWidth: CGFloat) {
        columns = min(3, max(1, count))
        headerHeight = stripSize.height
        let rows = (max(1, count) + columns - 1) / columns
        let width = CGFloat(columns) * (labelWidth + 48)
            + CGFloat(columns - 1) * Self.spacing + Self.horizontalInset * 2
        // The taller picker has deeper shoulders than a compact strip. Keep
        // the entire original strip inside those shoulders, not at its edge.
        size = CGSize(width: min(max(stripSize.width + Self.horizontalInset * 2, width), max(1, screenWidth - 24)),
                      height: headerHeight + CGFloat(rows) * Self.rowHeight
                        + CGFloat(rows - 1) * Self.spacing + Self.verticalInset * 2)
    }
}

enum NotchControlSetupRequirement: Equatable {
    case feature(AppFeature)
    case page(NotchModule, feature: AppFeature?)
    case none
}

enum NotchControlItem: String, CaseIterable, Identifiable {
    case keepAwake, speedTest, panel
    static let defaultHidden = "speedTest,panel"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .keepAwake: return "cup.and.saucer"
        case .speedTest: return "speedometer"
        // The app panel opens as a bubble under the menu bar icon.
        case .panel: return "bubble.middle.top"
        }
    }

    var setupRequirement: NotchControlSetupRequirement {
        switch self {
        case .keepAwake: return .feature(.keepAwake)
        case .panel: return .none
        case .speedTest: return .page(.system, feature: .monitorNetwork)
        }
    }

    func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .keepAwake: return AppFeature.keepAwake.isAvailable(in: defaults)
        case .speedTest: return AppFeature.monitorNetwork.isAvailable(in: defaults) && NotchSupport.modules(in: defaults).contains(.system)
        case .panel: return true
        }
    }
}

enum NotchQuickAccessSide: String, CaseIterable, Codable {
    case left, right, bottom
}

enum NotchQuickAction: Hashable, Identifiable {
    case explore, settings, pin, module(NotchModule), control(NotchControlItem)

    var id: String {
        switch self {
        case .explore: return "explore"
        case .settings: return "settings"
        case .pin: return "pin"
        case .module(let module): return module.rawValue
        case .control(let item): return "control." + item.rawValue
        }
    }

    init?(id: String) {
        switch id {
        case "explore": self = .explore
        case "settings": self = .settings
        case "pin": self = .pin
        default:
            if id.hasPrefix("control."), let item = NotchControlItem(rawValue: String(id.dropFirst(8))) {
                self = .control(item)
            } else if let module = NotchModule(rawValue: id) { self = .module(module) }
            else { return nil }
        }
    }

    static var optionalActions: [Self] {
        [.explore, .settings, .pin] + NotchModule.allCases.map(Self.module)
            + NotchControlItem.allCases.map(Self.control)
    }

    func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .module(let module): return NotchSupport.modules(in: defaults).contains(module)
        case .control(let item): return item.isAvailable(in: defaults)
        default: return true
        }
    }
}

struct NotchQuickButton: Codable, Equatable, Identifiable {
    var id: UUID
    var actionID: String
    var side: NotchQuickAccessSide
    var label: String

    init(id: UUID = UUID(), action: NotchQuickAction, side: NotchQuickAccessSide, label: String = "") {
        self.id = id
        actionID = action.id
        self.side = side
        self.label = label
    }

    var action: NotchQuickAction? { NotchQuickAction(id: actionID) }
}

struct NotchQuickAccessConfiguration: Equatable, Codable {
    var buttons: [NotchQuickButton]
    private var version = 1
    static let maximumPerSide = 3
    static let initial = Self(buttons: [
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, action: .explore, side: .left),
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, action: .module(.system), side: .left),
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, action: .settings, side: .right),
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, action: .module(.agents), side: .right),
    ])
    var actions: [NotchQuickAction] { buttons.compactMap(\.action) }
    var hasBottom: Bool { buttons.contains { $0.side == .bottom } }

    init(buttons: [NotchQuickButton]) { self.buttons = buttons }

    /// Stable IDs allow the previous single-side preferences to remain live
    /// until the first deliberate edit saves the new layout.
    init(side: NotchQuickAccessSide, actions: [NotchQuickAction]) {
        buttons = actions.enumerated().map { index, action in
            NotchQuickButton(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                             action: action, side: side)
        }
    }

    func sanitized() -> Self {
        var ids = Set<UUID>()
        var counts: [NotchQuickAccessSide: Int] = [:]
        let safe = buttons.prefix(64).compactMap { button -> NotchQuickButton? in
            guard button.action != nil, ids.insert(button.id).inserted,
                  counts[button.side, default: 0] < Self.maximumPerSide else { return nil }
            counts[button.side, default: 0] += 1
            var result = button
            result.label = String(button.label.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            return result
        }
        return Self(buttons: safe)
    }

    var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(sanitized())) ?? Data()
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: DefaultsKey.notchQuickAccessLayout), !data.isEmpty, data.count <= 32_768,
           let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 {
            return value.sanitized()
        }
        // These retired keys have no registration defaults, so even an empty
        // saved value is an explicit legacy choice rather than a fresh install.
        let legacyKeys = [DefaultsKey.notchQuickAccessSide, DefaultsKey.notchQuickAccessSecond, DefaultsKey.notchQuickAccessThird]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return .initial }
        let side = NotchQuickAccessSide(rawValue: defaults.string(forKey: DefaultsKey.notchQuickAccessSide) ?? "") ?? .left
        var actions: [NotchQuickAction] = [.explore]
        for key in [DefaultsKey.notchQuickAccessSecond, DefaultsKey.notchQuickAccessThird] {
            let id = defaults.string(forKey: key) ?? (key == DefaultsKey.notchQuickAccessSecond ? NotchQuickAction.settings.id : "")
            guard let action = NotchQuickAction(id: id),
                  !actions.contains(action) else { continue }
            actions.append(action)
        }
        return Self(side: side, actions: actions)
    }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        var configuration = stored(in: defaults)
        configuration.buttons = configuration.shown(in: defaults)
        return configuration
    }

    /// The buttons the island shows. One whose section or feature is off
    /// keeps its place, so it comes back there once that is on again.
    func shown(in defaults: UserDefaults = .standard) -> [NotchQuickButton] {
        buttons.filter { $0.action?.isAvailable(in: defaults) == true }
    }

    /// Whether a side has a free place. A hidden button still holds its own.
    func hasRoom(on side: NotchQuickAccessSide) -> Bool {
        buttons.filter { $0.side == side }.count < Self.maximumPerSide
    }

    /// Swaps a button with its neighbour on the same side. False when it is
    /// already at that end, so there is nothing to save.
    @discardableResult
    mutating func reorder(_ id: UUID, by offset: Int) -> Bool {
        guard let from = buttons.firstIndex(where: { $0.id == id }) else { return false }
        let side = buttons[from].side
        let items = buttons.filter { $0.side == side }
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset),
              let to = buttons.firstIndex(where: { $0.id == items[index + offset].id }) else { return false }
        buttons.swapAt(from, to)
        return true
    }

    mutating func move(_ id: UUID, to side: NotchQuickAccessSide, before target: UUID? = nil) {
        guard let index = buttons.firstIndex(where: { $0.id == id }),
              buttons[index].side == side || hasRoom(on: side) else { return }
        var item = buttons.remove(at: index)
        item.side = side
        let destination = target.flatMap { target in buttons.firstIndex(where: { $0.id == target && $0.side == side }) }
        buttons.insert(item, at: destination ?? buttons.endIndex)
    }
}

struct NotchQuickAccessPlacement: Equatable, Identifiable {
    let button: NotchQuickButton
    let index: Int
    let edge: CGFloat
    let top: CGFloat
    var id: UUID { button.id }
    var side: NotchQuickAccessSide { button.side }
    func center(progress: CGFloat) -> CGPoint {
        NotchQuickAccessLayout.center(index: index, progress: progress, edge: edge, top: top, side: side)
    }
}

/// All coordinates are in the flipped presentation container, including the
/// transparent space reserved beside the black notch.
enum NotchQuickAccessLayout {
    static let diameter: CGFloat = 44
    static let gap: CGFloat = 12
    static let gutter: CGFloat = 72
    static let rowSpacing: CGFloat = 54
    static let withdrawalDuration = 0.16
    static let hoverMargin: CGFloat = 16
    static let hoverExitDelay = 0.18

    static func center(index: Int, progress: CGFloat, edge: CGFloat, top: CGFloat,
                       side: NotchQuickAccessSide) -> CGPoint {
        let phase = progress.isFinite ? min(1.1, max(0, progress)) : 0
        let offset = -14 + phase * (14 + gap + diameter / 2)
        if side == .bottom { return CGPoint(x: top + CGFloat(index) * rowSpacing, y: edge + offset) }
        return CGPoint(x: edge + (side == .left ? -offset : offset), y: top + CGFloat(index) * rowSpacing)
    }

    /// Hover is a continuous corridor, including the gaps and a forgiving rim.
    /// Clicks still use the exact circles below.
    static func hoverRect(count: Int, edge: CGFloat, top: CGFloat,
                          side: NotchQuickAccessSide) -> CGRect {
        guard count > 0 else { return .null }
        let first = center(index: 0, progress: 1, edge: edge, top: top, side: side)
        let last = center(index: min(3, count) - 1, progress: 1, edge: edge, top: top, side: side)
        let radius = diameter / 2
        if side == .bottom {
            return CGRect(x: first.x - radius, y: edge, width: last.x - first.x + diameter,
                          height: first.y + radius - edge).insetBy(dx: -hoverMargin, dy: -hoverMargin)
        }
        return CGRect(x: min(first.x - radius, edge), y: first.y - radius,
                      width: max(first.x + radius, edge) - min(first.x - radius, edge),
                      height: last.y - first.y + diameter)
            .insetBy(dx: -hoverMargin, dy: -hoverMargin)
    }

    static func placements(_ configuration: NotchQuickAccessConfiguration, body: CGRect, headerTop: CGFloat) -> [NotchQuickAccessPlacement] {
        var indices: [NotchQuickAccessSide: Int] = [:]
        let count = { (side: NotchQuickAccessSide) in configuration.buttons.filter { $0.side == side }.count }
        // Short pages lift a crowded column to balance its top and bottom
        // margins, and the other column with it, so the two start level.
        // Keep the usual header alignment when there is room.
        let sideSpan = CGFloat(max(count(.left), count(.right)) - 1) * rowSpacing
        let sideTop = max(body.minY + diameter / 2 + gap, min(headerTop, body.midY - sideSpan / 2))
        return configuration.buttons.map { button in
            let index = indices[button.side, default: 0]
            indices[button.side] = index + 1
            let edge = button.side == .bottom ? body.maxY : button.side == .left ? body.minX : body.maxX
            let span = CGFloat(count(button.side) - 1) * rowSpacing
            let top = button.side == .bottom ? body.midX - span / 2 : sideTop
            return NotchQuickAccessPlacement(button: button, index: index, edge: edge, top: top)
        }
    }

    static func hitTest(_ point: CGPoint, count: Int, edge: CGFloat, top: CGFloat,
                        side: NotchQuickAccessSide) -> Bool {
        (0..<max(0, min(3, count))).contains { index in
            let center = center(index: index, progress: 1, edge: edge, top: top, side: side)
            return hypot(point.x - center.x, point.y - center.y) <= diameter / 2
        }
    }
}

enum NotchEvent: String, CaseIterable {
    case battery, clipboard, agents, inputSource

    var preferenceKey: String {
        switch self {
        case .agents: return DefaultsKey.notchAgentsEnabled
        case .inputSource: return DefaultsKey.notchInputSource
        case .battery: return DefaultsKey.notchBattery
        case .clipboard: return DefaultsKey.notchClipboard
        }
    }

    var priority: Int {
        switch self {
        case .inputSource: return 3
        case .battery, .agents: return 1
        case .clipboard: return 0
        }
    }

    var duration: TimeInterval {
        switch self {
        case .inputSource: return 1.6
        case .agents: return 5
        case .battery: return 4
        case .clipboard: return 2.5
        }
    }
}

enum NotchSupport {
    /// Whether a connected display has a camera housing, wherever the island
    /// is: it can be off, withdrawn with the lid closed or on another display.
    static var hasNotchedDisplay: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// Whether a connected display, such as an external monitor, has no
    /// camera housing, so the island can float there as a capsule.
    static var hasDisplayWithoutNotch: Bool {
        NSScreen.screens.contains { !($0.safeAreaInsets.top > 0) }
    }

    static let defaultHoverDelay = 0.25
    static let hoverDelayRange = 0.10...1.0

    /// Whether a screen point lies in a top-edge click area, whose top edge
    /// belongs to it as in the flipped native view.
    static func screenEdgeArea(_ area: CGRect, contains point: CGPoint) -> Bool {
        CGRect(origin: .zero, size: area.size).contains(CGPoint(x: point.x - area.minX, y: area.maxY - point.y))
    }

    static func sanitizedHoverDelay(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(hoverDelayRange.upperBound, max(hoverDelayRange.lowerBound, value)) : defaultHoverDelay
    }

    /// How long an island opened by hover waits after the pointer leaves.
    static let defaultCloseDelay = NotchQuickAccessLayout.hoverExitDelay
    static let closeDelayRange = 0.10...2.0

    static func sanitizedCloseDelay(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(closeDelayRange.upperBound, max(closeDelayRange.lowerBound, value)) : defaultCloseDelay
    }

    /// An unset value keeps the old pause rather than reading as zero.
    static func closeDelay(in defaults: UserDefaults = .standard) -> TimeInterval {
        sanitizedCloseDelay(defaults.object(forKey: DefaultsKey.notchCloseDelay) as? Double ?? defaultCloseDelay)
    }

    static func moduleShortcut(_ characters: String, modules: [NotchModule]) -> NotchModule? {
        modules.first { $0.shortcutKey == characters.lowercased() }
    }

    static func filteredModules(_ modules: [NotchModule], query: String,
                                title: (NotchModule) -> String) -> [NotchModule] {
        let terms = NotchSearch.normalized(query).split(separator: " ")
        guard !terms.isEmpty else { return modules }
        return modules.filter { module in
            let name = NotchSearch.normalized(title(module))
            return terms.allSatisfy { name.contains($0) }
        }
    }

    static func adjacentModule(to selected: NotchModule?, modules: [NotchModule], backwards: Bool) -> NotchModule? {
        guard !modules.isEmpty else { return nil }
        guard let selected, let index = modules.firstIndex(of: selected) else { return modules.first }
        return modules[(index + (backwards ? modules.count - 1 : 1)) % modules.count]
    }

    /// The arrow keys step through a searched list without wrapping; the
    /// first press, or one after the highlighted row left the list, lands on
    /// the top result.
    static func steppedItem<ID: Equatable>(from current: ID?, in ids: [ID], backwards: Bool) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(index + (backwards ? -1 : 1), 0), ids.count - 1)]
    }

    /// Return can paste before an arrow is pressed. A stale highlight falls
    /// back to the first visible entry, never to a filtered-out row.
    static func clipboardPasteTarget<ID: Equatable>(highlighted: ID?, in ids: [ID]) -> ID? {
        if let highlighted, ids.contains(highlighted) { return highlighted }
        return ids.first
    }

    /// The row a search leaves highlighted: the current one while it is still
    /// listed, otherwise the top result of a typed search, so Return pastes it
    /// like the history window does. An empty search waits for the first arrow.
    static func searchHighlight<ID: Equatable>(keeping current: ID?, in ids: [ID], query: String) -> ID? {
        if let current, ids.contains(current) { return current }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ids.first
    }

    /// What opening the clipboard highlights: the entry copied last. Pinned
    /// entries sit above the recent ones, so it is the first one that is not
    /// pinned; with only pinned entries, the top of the list.
    static func restingClipboardHighlight<ID>(_ entries: [(ID, Bool)]) -> ID? {
        (entries.first { !$0.1 } ?? entries.first)?.0
    }

    /// What a key does on the clipboard page, whose search field keeps the
    /// focus while hidden. Up/Down, Control-P/N and Return drive the list.
    /// A typed letter shows the field and goes on to it, so its editor and any input method
    /// get every key, and so does every key while an input method composes.
    /// Other Command, Control or Option keys belong to their own shortcuts;
    /// Shift with the arrows or Return stays with the field, which selects with them.
    static func clipboardKey(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                             composing: Bool) -> NotchClipboardKey? {
        let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
        if !composing, shortcutModifiers == .control {
            switch characters.lowercased() {
            case "n": return .move(backwards: false)
            case "p": return .move(backwards: true)
            default: break
            }
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        guard !composing else { return .reveal }
        switch keyCode {
        case 125, 126: return modifiers.contains(.shift) ? nil : .move(backwards: keyCode == 126)
        case 36, 76: return modifiers.contains(.shift) ? nil : .paste
        default: break
        }
        // Function and arrow keys report private-use characters.
        let typed = !characters.isEmpty && !characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
        return typed ? .reveal : nil
    }

    /// How far an open clipboard entry, drawn over the list from its row's top,
    /// moves so all of it shows: up just enough where it would pass the bottom,
    /// down to the top where its row is partly scrolled away. It always covers
    /// the part of its row in view, so the pointer resting there stays on it,
    /// and once the row has left the list it never moves past the row's edge,
    /// so it scrolls away with its row instead of staying over the others.
    static func clipboardOpenOffset(rowTop: CGFloat, rowHeight: CGFloat, height: CGFloat,
                                    visibleHeight: CGFloat) -> CGFloat {
        min(rowHeight, max(-height, max(-rowTop, min(0, visibleHeight - rowTop - height))))
    }

    /// How many whole rows a clipboard list still at its top, as the page
    /// opens, moves to bring row `index` into view: none while at least
    /// `shown` points of that row show within `visibleHeight`, and otherwise
    /// the fewest that show that much. Moving by whole rows keeps the row at
    /// the list's top whole, where moving only as far as the row needs would
    /// leave the one above it cut to its last few points.
    static func clipboardOpeningScroll(index: Int, rowHeight: CGFloat, spacing: CGFloat, shown: CGFloat,
                                       visibleHeight: CGFloat) -> Int {
        let lowest = ((visibleHeight - min(shown, rowHeight)) / (rowHeight + spacing)).rounded(.down)
        return min(max(0, index), max(0, index - Int(lowest)))
    }

    /// Automatic order until the user chooses one of the live activities.
    static func compactActivity(agents: Bool, keepAwake: Bool = false) -> NotchCompactActivity? {
        compactActivities(agents: agents, keepAwake: keepAwake).first
    }

    /// Keep Awake comes last: a session can run all day, and it only says
    /// that the Mac stays awake.
    static func compactActivities(agents: Bool, keepAwake: Bool = false) -> [NotchCompactActivity] {
        let candidates: [(Bool, NotchCompactActivity)] = [(agents, .agents), (keepAwake, .keepAwake)]
        return candidates.compactMap { $0.0 ? $0.1 : nil }
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        AppFeature.notch.isAvailable(in: defaults)
            && defaults.bool(forKey: DefaultsKey.notchEnabled)
    }

    static func usesHapticFeedback(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchHapticFeedback)
    }

    /// Whether the island's own shortcut should hold its key.
    static func holdsShortcut(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchShortcutEnabled)
    }

    static func modules(in defaults: UserDefaults = .standard) -> [NotchModule] {
        let hidden = Set((defaults.string(forKey: DefaultsKey.notchHiddenModules) ?? "")
            .split(separator: ",").map(String.init))
        let stored = (defaults.string(forKey: DefaultsKey.notchModuleOrder) ?? "")
            .split(separator: ",").compactMap { NotchModule(rawValue: String($0)) }
        var seen = Set<NotchModule>()
        return (stored + NotchModule.allCases).filter {
            seen.insert($0).inserted && !hidden.contains($0.rawValue) && $0.isAvailable(in: defaults)
                && ($0 != .agents || defaults.bool(forKey: DefaultsKey.notchAgentsEnabled))
        }
    }

    static func showsInCaptures(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.notchShowInCaptures) as? Bool ?? true
    }

    /// The closed island may cover the menus instead of giving way to them.
    static func coversMenus(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.notchCoversMenus) as? Bool ?? true
    }

    static let defaultLowBatteryThreshold = 10
    /// Both level sliders share this scale so their knobs line up; red stops
    /// one short of the top so amber always has room above it.
    static let batteryLevelScale = 1...100
    static let lowBatteryThresholdRange = 1...99
    static let defaultEarlyBatteryThreshold = 20
    static let earlyBatteryThresholdRange = 2...100

    static func sanitizedLowBatteryThreshold(_ value: Int) -> Int {
        min(lowBatteryThresholdRange.upperBound, max(lowBatteryThresholdRange.lowerBound, value))
    }

    static func sanitizedEarlyBatteryThreshold(_ value: Int) -> Int {
        min(earlyBatteryThresholdRange.upperBound, max(earlyBatteryThresholdRange.lowerBound, value))
    }

    /// The amber level, kept at least one point above the red one so the
    /// early warning always comes first.
    static func earlyBatteryThreshold(_ value: Int, above red: Int) -> Int {
        max(sanitizedEarlyBatteryThreshold(value), sanitizedLowBatteryThreshold(red) + 1)
    }

    /// The charge turns red at or below the chosen level once the person asks
    /// for it, and amber a little earlier when they want a first warning.
    /// Neither shows while the Mac is plugged in.
    static func batteryWarning(percent: Int?, externalConnected: Bool, tint: Bool, threshold: Int,
                               early: Bool = false, earlyThreshold: Int = defaultEarlyBatteryThreshold) -> BatteryWarning {
        guard tint, !externalConnected, let percent else { return .none }
        if percent <= sanitizedLowBatteryThreshold(threshold) { return .low }
        if early, percent <= sanitizedEarlyBatteryThreshold(earlyThreshold) { return .early }
        return .none
    }

    static func batteryWarning(percent: Int?, externalConnected: Bool,
                               in defaults: UserDefaults = .standard) -> BatteryWarning {
        batteryWarning(percent: percent, externalConnected: externalConnected,
                       tint: defaults.bool(forKey: DefaultsKey.notchLowBatteryTint),
                       threshold: defaults.object(forKey: DefaultsKey.notchLowBatteryThreshold) as? Int
                           ?? defaultLowBatteryThreshold,
                       early: defaults.bool(forKey: DefaultsKey.notchLowBatteryEarly),
                       earlyThreshold: defaults.object(forKey: DefaultsKey.notchLowBatteryEarlyThreshold) as? Int
                           ?? defaultEarlyBatteryThreshold)
    }

    /// The menu bar's battery reading follows the same warning unless the
    /// person keeps it to the island.
    static func menuBarBatteryWarning(percent: Int?, externalConnected: Bool,
                                      in defaults: UserDefaults = .standard) -> BatteryWarning {
        guard defaults.object(forKey: DefaultsKey.notchLowBatteryMenuBar) as? Bool ?? true else { return .none }
        return batteryWarning(percent: percent, externalConnected: externalConnected, in: defaults)
    }

    /// The closed island stays out of sight until the pointer reaches it.
    /// Unless set to show activity, it shows no notices while it waits.
    static func hidesUntilHover(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: DefaultsKey.notchHideUntilHover) && defaults.bool(forKey: DefaultsKey.notchOpenOnHover)
    }

    /// Hidden until hover, the island can still come into sight for as long
    /// as an activity runs or a notice shows, and then it takes notices.
    static func hiddenShowsActivity(in defaults: UserDefaults = .standard) -> Bool {
        hidesUntilHover(in: defaults) && defaults.bool(forKey: DefaultsKey.notchHiddenShowsActivity)
    }

    static func idleContent(in defaults: UserDefaults = .standard) -> NotchIdleContent {
        let choice = NotchIdleContent(rawValue: defaults.string(forKey: DefaultsKey.notchIdleContent) ?? "") ?? .none
        return canRest(with: choice, in: defaults) ? choice : .none
    }

    /// Whether the closed island can rest with this content now. A choice it
    /// cannot show waits, still chosen, until its section or feature is back.
    /// The island's own switch stands apart, since it rules out every choice.
    static func canRest(with content: NotchIdleContent, in defaults: UserDefaults = .standard) -> Bool {
        switch content {
        case .none: return true
        case .battery: return AppFeature.monitorPower.isAvailable(in: defaults)
        case .agents: return NotchAgentSupport.sectionShows(in: defaults)
        }
    }

    static func controls(in defaults: UserDefaults = .standard) -> [NotchControlItem] {
        let hidden = Set((defaults.string(forKey: DefaultsKey.notchHiddenControls) ?? NotchControlItem.defaultHidden)
            .split(separator: ",").map(String.init))
        let stored = (defaults.string(forKey: DefaultsKey.notchControlOrder) ?? "")
            .split(separator: ",").compactMap { NotchControlItem(rawValue: String($0)) }
        var seen = Set<NotchControlItem>()
        return (stored + NotchControlItem.allCases).filter {
            seen.insert($0).inserted && !hidden.contains($0.rawValue) && $0.isAvailable(in: defaults)
        }
    }

    /// Power draw has a card of its own beside the battery; fans join once
    /// the monitor reports one.
    static func systemCardCount(hasBattery: Bool, fans: Int = 0, in defaults: UserDefaults = .standard) -> Int {
        [.monitorCPU, .monitorGPU, .monitorMemory, .monitorDisk].filter {
            (feature: AppFeature) in feature.isAvailable(in: defaults)
        }.count + (AppFeature.monitorNetwork.isAvailable(in: defaults) ? 1 : 0)
            + (hasBattery && AppFeature.monitorPower.isAvailable(in: defaults) ? 1 : 0)
            + (AppFeature.monitorPower.isAvailable(in: defaults) ? 1 : 0)
            + (fans > 0 && AppFeature.fanControl.isAvailable(in: defaults) ? 1 : 0)
            + (AppFeature.connectedDevices.isAvailable(in: defaults) ? 1 : 0)
    }

    /// Direct openings are dismissed explicitly, never by the pointer's
    /// initial position at the menu bar or in the application being used.
    static func closesOnPointerExit(expanded: Bool, peeking: Bool, openedByHover: Bool) -> Bool {
        peeking || (expanded && openedByHover)
    }

    /// Another app becoming active closes the open island like a click away.
    /// One opened by hover stays while the pointer rests on it unclicked:
    /// reaching the island can itself make the app beneath it active, such as
    /// a full-screen app on a display without focus, and leaving closes it
    /// anyway. A click inside may be what brought the other app forward.
    static func closesOnActivation(openedByHover: Bool, clicked: Bool, pointerInside: Bool) -> Bool {
        !openedByHover || clicked || !pointerInside
    }

    static func routes(_ event: NotchEvent, in defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(in: defaults), defaults.bool(forKey: event.preferenceKey) else { return false }
        switch event {
        case .agents: return AppFeature.notchAgents.isAvailable(in: defaults)
            && modules(in: defaults).contains(.agents)
        case .battery: return AppFeature.monitorPower.isAvailable(in: defaults)
        case .clipboard:
            return modules(in: defaults).contains(.clipboard)
                && defaults.bool(forKey: DefaultsKey.clipboardHistoryEnabled)
        // A layout notice needs no feature of its own, only its own toggle.
        case .inputSource: return true
        }
    }

    static func routesClipboardWindow(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchClipboardWindow)
            && modules(in: defaults).contains(.clipboard)
    }

    static func routesAppPanel(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchAppPanel)
    }

    /// A notice gives way only to one at least as urgent.
    static func shouldReplace(_ current: NotchEvent?, with incoming: NotchEvent) -> Bool {
        guard let current else { return true }
        return incoming.priority >= current.priority
    }

    /// A laptop with its lid closed has no built-in screen to show on, so the
    /// built-in choice hides the island there. A Mac without a built-in panel
    /// never has one, so that choice keeps the main display. The pointer
    /// choice takes the display it last followed the pointer to, if any, and
    /// so does the choice of every display for the island that responds.
    static func screenIndex(preference: NotchDisplay, builtIn: [Bool], notched: [Bool], main: Int,
                            pointer: Int? = nil, hasLid: Bool = true) -> Int? {
        guard !builtIn.isEmpty, builtIn.count == notched.count else { return nil }
        let fallback = builtIn.indices.contains(main) ? main : 0
        switch preference {
        case .main: return fallback
        case .builtIn: return builtIn.firstIndex(of: true) ?? (hasLid ? nil : fallback)
        case .automatic:
            return builtIn.indices.first { builtIn[$0] && notched[$0] }
                ?? notched.firstIndex(of: true) ?? fallback
        case .pointer, .all: return pointer.flatMap { builtIn.indices.contains($0) ? $0 : nil } ?? fallback
        }
    }

    /// Whether the island can rest on a display without a notch, where the
    /// shape chosen for those displays shows. The pointer can take it to any
    /// display; otherwise the chosen display decides, and one with a camera,
    /// or a built-in screen closed under its lid, keeps it off all of them.
    static func reachesDisplayWithoutNotch(preference: NotchDisplay, builtIn: [Bool], notched: [Bool], main: Int,
                                           hasLid: Bool = true) -> Bool {
        guard notched.contains(false) else { return false }
        if preference == .pointer || preference == .all { return true }
        guard let index = screenIndex(preference: preference, builtIn: builtIn, notched: notched, main: main,
                                      hasLid: hasLid) else { return false }
        return !notched[index]
    }
}

/// A hidden menu bar retains only a measurement from the same display and mode.
/// Until that display has a visible bar, use the native fallback rather than
/// borrowing the application's main-menu height from another display.
struct NotchMenuBarMeasurements {
    private struct Reading {
        let size: CGSize
        let scale: CGFloat
        let height: CGFloat
    }
    private static let range: ClosedRange<CGFloat> = 16...64
    private var readings: [UInt32: Reading] = [:]

    /// A bar that hides until the pointer reveals it reserves nothing at the
    /// top of the visible frame, and neither does a display without a bar.
    static func showsBar(frame: CGRect, visibleTop: CGFloat) -> Bool {
        let gap = frame.maxY - visibleTop
        return gap.isFinite && range.contains(gap)
    }

    mutating func retainDisplays(_ ids: [UInt32]) {
        readings = readings.filter { ids.contains($0.key) }
    }

    mutating func height(displayID: UInt32, frame: CGRect, visibleTop: CGFloat,
                         scale: CGFloat, statusBarThickness: CGFloat) -> CGFloat {
        let range = Self.range
        let gap = frame.maxY - visibleTop
        let canRemember = displayID != 0 && scale.isFinite && scale > 0
        if let previous = readings[displayID], previous.size != frame.size || previous.scale != scale {
            readings[displayID] = nil
        }
        if Self.showsBar(frame: frame, visibleTop: visibleTop) {
            if canRemember { readings[displayID] = Reading(size: frame.size, scale: scale, height: gap) }
            return gap
        }
        if canRemember, let previous = readings[displayID] { return previous.height }
        return statusBarThickness.isFinite && range.contains(statusBarThickness) ? statusBarThickness : 24
    }
}

/// Screen coordinates stay in points, including displays to the left or above
/// the primary display. No model name or pixel density is assumed.
/// The two sides of a closed notice beside the camera, each as wide as
/// what it shows.
struct NotchNoticeWings: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
    static let zero = NotchNoticeWings(leading: 0, trailing: 0)
}

struct NotchGeometry: Equatable {
    let screen: CGRect
    /// How far the island's centre sits right of the camera's: a closed
    /// notice reaches further toward its wider side. Zero everywhere else.
    var surfaceShift: CGFloat = 0
    let cameraWidth: CGFloat
    /// The island's camera region, including optional menu-bar coverage,
    /// manual fit and outline clearance, rather than just the hardware inset.
    let cameraHeight: CGFloat
    let isNotched: Bool
    let layout: NotchSize
    let customWidth: CGFloat
    let customHeight: CGFloat
    let menuBarHeight: CGFloat
    /// Nil hangs the island from the top edge. A capsule floats this far
    /// inside the menu bar, above and below its strips.
    let floatingGap: CGFloat?
    /// How far a fitted capsule sits below the top of the display, open or closed.
    let floatingDrop: CGFloat
    /// How far past a physical camera an outlined island reaches on each side
    /// and below. The line is drawn inside the island's edge, so an island
    /// that only covers the camera would hide it behind the housing.
    let outlineRoom: CGFloat
    private let capsuleWidthFit: CGFloat
    var compactSideRoom: CGFloat?
    var quickAccessBottomInset: CGFloat = 0
    var requiresFullWidthHeader = false
    /// What the open page puts in the island's top row.
    var pageTop: NotchPageTop = .row
    /// The width the open page reads best at, inside a preset's width,
    /// which stays the limit; nil takes all of it, as lists do. A width set
    /// by hand is the island's on every page.
    var pageContentWidth: CGFloat? = nil
    /// Nothing floating beside the island leads to its sections, so the
    /// open page's row starts with the island's own button for them.
    var sectionsButtonInRow = false
    private var allowsActivityFooter = true
    private var minimumCompactWidth: CGFloat = 0
    /// Narrower wings than this are dropped rather than drawn cramped.
    private var minimumWing: CGFloat = 44

    init(screen: CGRect, safeAreaTop: CGFloat, cameraWidth: CGFloat, layout: NotchSize = .compact,
         menuBarHeight: CGFloat = 24, compactSideRoom: CGFloat? = nil,
         customWidth: Double = NotchSize.defaultWidth, customHeight: Double = NotchSize.defaultHeight,
         cameraFit: NotchCameraFit = .zero, silhouette: NotchSilhouette = .notch, capsuleFit: NotchCapsuleFit = .zero,
         hideMenuBarGap: Bool = false, outline: Bool = false, barEdge: CGFloat = 0) {
        self.screen = screen
        self.layout = layout
        self.customWidth = NotchSize.clamped(customWidth, to: NotchSize.widthRange, fallback: NotchSize.defaultWidth)
        self.customHeight = NotchSize.clamped(customHeight, to: NotchSize.heightRange, fallback: NotchSize.defaultHeight)
        let barHeight = menuBarHeight.isFinite ? min(64, max(16, menuBarHeight)) : 24
        isNotched = safeAreaTop.isFinite && safeAreaTop > 0 && cameraWidth.isFinite && cameraWidth > 0
        // Only a physical camera has an outline to match; a simulated one follows the bar.
        let fit = isNotched ? cameraFit : .zero
        // A capsule replaces only a simulated cutout. It is as wide as the
        // cutout of the bar it sits in with its usual margins, so a bar hidden
        // on one display and shown on another draws the same capsule on both.
        let gap: CGFloat? = !isNotched && silhouette == .capsule ? NotchLayout.capsuleGap(barHeight: barHeight) : nil
        floatingGap = gap
        // A fitted capsule grows from its top edge, keeping its margins.
        let capsuleFit = gap == nil ? NotchCapsuleFit.zero : capsuleFit
        floatingDrop = capsuleFit.drop
        capsuleWidthFit = capsuleFit.width
        // The bar ends in a hairline, `barEdge` thick, that reads as its edge:
        // the capsule's margin below is measured from it, as the one above is
        // from the top of the display, so the capsule shows centred in the
        // bar. Its width keeps following the whole bar.
        let edge = barEdge.isFinite ? min(max(0, barEdge), 1) : 0
        let fullStrip = gap.map { max(barHeight + capsuleFit.height, $0 * 2 + 12) }
        let stripHeight = gap.map { max(barHeight - edge + capsuleFit.height, $0 * 2 + 12) } ?? barHeight
        let profileHeight = gap.flatMap { gap in fullStrip.map { $0 - (gap - NotchLayout.capsuleMargin) * 2 } }
            ?? barHeight
        // A capsule's camera is only the room it keeps, on whole points.
        let simulated = 180 * profileHeight / 32
        // A simulated cutout sits on the menu bar, where its outline already shows.
        let room = isNotched && outline ? NotchLayout.outlineWidth : 0
        outlineRoom = room
        self.cameraWidth = min(isNotched ? max(0, cameraWidth + fit.width + room * 2)
                               : gap == nil ? simulated : (simulated + capsuleFit.width).rounded(),
                               screen.width * 0.7)
        if isNotched {
            // The menu bar can extend slightly below the camera's safe area.
            // Optionally cover its full height before applying a manual fit.
            let baseHeight = hideMenuBarGap ? max(safeAreaTop, barHeight) : safeAreaTop
            cameraHeight = min(max(0, baseHeight + fit.height + room), 64)
        } else {
            cameraHeight = stripHeight
        }
        self.menuBarHeight = max(cameraHeight, barHeight)
        self.compactSideRoom = compactSideRoom
    }

    /// The island floats in the menu bar instead of hanging from the top edge.
    var floats: Bool { floatingGap != nil }

    func hasSameMenuBar(as other: NotchGeometry) -> Bool {
        screen == other.screen && cameraWidth == other.cameraWidth
            && menuBarHeight == other.menuBarHeight && isNotched == other.isNotched
    }

    /// Below a camera, or below the space it would take. A capsule has
    /// neither, so what it shows keeps even margins inside it.
    var safeContentTop: CGFloat { floats ? NotchLayout.bottomInset : cameraHeight + 10 }
    /// The top row wraps the camera, a page's own controls on either side,
    /// when each side keeps its wing: 100 points, which the compact preset
    /// leaves. Narrower layouts keep a full row below the camera.
    var headerCameraGap: CGFloat {
        isNotched && !requiresFullWidthHeader && contentWidth >= cameraWidth + Self.pageBandSide * 2 ? cameraWidth : 0
    }
    /// What each side of the camera keeps for the page's row.
    static let pageBandSide: CGFloat = 100

    /// The island opened on `module` at rest: the page's top row and the
    /// width it reads best at, with the sections button where nothing
    /// floating beside the island offers them.
    func page(_ module: NotchModule, controls: [NotchControlItem], sectionsButton: Bool) -> NotchGeometry {
        var result = self
        result.pageTop = module.pageTop
        result.pageContentWidth = NotchLayout.naturalContentWidth(module, controls: controls, within: contentWidth)
        result.sectionsButtonInRow = sectionsButton
        return result
    }
    /// A capsule's row keeps clear of its rounded top corners, its 28-point
    /// buttons as far from the top edge as the page is from the bottom. A
    /// page with no row starts as far from the top as it ends from the bottom.
    var headerTopInset: CGFloat {
        if isNotched, !floats { return headerCameraGap > 0 ? 0 : safeContentTop }
        guard headerRowHeight > 0 else { return NotchLayout.bottomInset }
        return floats ? NotchLayout.bottomInset - (NotchLayout.headerHeight - 28) / 2 : 0
    }
    /// The row beside a camera is there whatever the page, as the camera is;
    /// elsewhere only a page with something to put in it has one, or a page
    /// the row has to lead to the sections from.
    var headerRowHeight: CGFloat {
        if headerCameraGap > 0 { return max(cameraHeight, NotchLayout.headerHeight) }
        return pageTop == .row || sectionsButtonInRow ? NotchLayout.headerHeight : 0
    }
    /// From the top of the island to the top of the page.
    var pageTopInset: CGFloat {
        guard headerRowHeight > 0 else { return headerTopInset }
        return headerTopInset + headerRowHeight + NotchLayout.spacing
    }
    var headerChromeHeight: CGFloat { pageTopInset - headerTopInset + NotchLayout.bottomInset }
    /// Floating circles sit below the menu bar even when the top row wraps the camera.
    var quickAccessCenterY: CGFloat {
        max(headerTopInset + headerRowHeight / 2,
            menuBarHeight + 6 + NotchQuickAccessLayout.diameter / 2)
    }
    /// One row beside the camera, including menu-bar coverage when enabled.
    var stripHeight: CGFloat { cameraHeight }
    /// What a strip shows inside: all of it, or the capsule within its margins.
    var stripBodyHeight: CGFloat { max(0, stripHeight - (floatingGap ?? 0) * 2) }
    func activationArea(in size: CGSize, hasHeader: Bool, compactActivity: Bool, expandedHeader: Bool = false) -> CGRect {
        // Open, only the camera toggles the island: beside it the row holds
        // the page's controls. A row below the camera leaves the strip above
        // it, and an island without a camera has nothing to toggle from.
        if expandedHeader, headerCameraGap > 0 || !isNotched || floats {
            return CGRect(x: (size.width - headerCameraGap) / 2, y: 0,
                          width: headerCameraGap, height: min(cameraHeight, size.height))
        }
        // A capsule has no camera to toggle from: all of it opens the island.
        let width = compactActivity && !floats ? cameraWidth : size.width
        let height = hasHeader ? min(safeContentTop, size.height)
            : compactActivity && compactActivityUsesFooter ? compactActivityTopPadding : size.height
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }

    var restingWingWidth: CGFloat {
        let available = min(44, max(0, compactSideRoom ?? 0)).rounded(.down)
        return available >= 44 ? available : 0
    }
    var collapsed: CGSize {
        CGSize(width: min(screen.width - 24, cameraWidth + restingWingWidth * 2), height: stripHeight)
    }
    func restingSize(showsContent: Bool) -> CGSize {
        if showsContent { return collapsed }
        // Bare, a capsule is shorter than the gap between an activity's
        // wings, closer to the phone's proportions, and on whole points,
        // as the window around it is.
        guard floats else { return CGSize(width: cameraWidth, height: cameraHeight) }
        let shoulders = NotchLayout.shoulder(height: stripHeight) * 2
        let capsule = max(NotchLayout.capsuleRestingAspect * stripBodyHeight + capsuleWidthFit, stripBodyHeight * 2)
        return CGSize(width: min(cameraWidth, (capsule + shoulders).rounded()), height: cameraHeight)
    }
    /// Full screen and the Lock Screen remove outline clearance while keeping
    /// the chosen menu-bar coverage and manual fit.
    var bareCutout: CGSize {
        let resting = restingSize(showsContent: false)
        return CGSize(width: max(0, resting.width - outlineRoom * 2), height: max(0, resting.height - outlineRoom))
    }
    /// A Keep Awake session keeps its reading beside the camera, never
    /// below it. Both wings take the width the wider side needs, so a short
    /// reading leaves no band of empty black at the ends.
    func compactKeepAwakeGeometry(wing fitted: CGFloat = NotchKeepAwakeSupport.stripWingRange.upperBound) -> NotchGeometry {
        var compact = self
        let room = compactSideRoom ?? 0
        let range = NotchKeepAwakeSupport.stripWingRange
        let wing = min(range.upperBound, max(range.lowerBound, fitted.isFinite ? fitted.rounded(.up) : 0))
        compact.compactSideRoom = room.isFinite && room >= 64 ? min(wing, room) : 0
        // A wider simulated camera must not consume the reading's text budget.
        compact.minimumCompactWidth = cameraWidth + wing * 2
        // Menu changes, including full-screen transitions, must not push the
        // reading below the camera. Its expanded view remains available by click.
        compact.allowsActivityFooter = false
        return compact
    }
    /// A working agent keeps its mark and one reading beside the camera,
    /// never below it, like Keep Awake. Both wings take the width the reading
    /// needs, so a short one leaves no band of empty black at the ends.
    func compactAgentGeometry(wing: CGFloat) -> NotchGeometry {
        var compact = self
        let room = compactSideRoom ?? 0
        let fitted = min(NotchAgentSupport.stripWingRange.upperBound,
                         max(NotchAgentSupport.stripWingRange.lowerBound, wing.isFinite ? wing.rounded(.up) : 0))
        compact.compactSideRoom = room.isFinite && room >= NotchAgentSupport.stripWingRange.lowerBound ? min(fitted, room) : 0
        compact.minimumCompactWidth = cameraWidth + fitted * 2
        compact.allowsActivityFooter = false
        return compact
    }
    var activityStrip: CGSize {
        let preferred = min(max(layout == .spacious ? 520 : 440, cameraWidth + 88, minimumCompactWidth), screen.width - 24)
        let measuredRoom = compactSideRoom ?? 0
        let room = measuredRoom.isFinite ? max(0, measuredRoom).rounded(.down) : 0
        let wings = min(max(0, preferred - cameraWidth), room * 2)
        return CGSize(width: cameraWidth + (wings >= minimumWing * 2 ? wings : 0), height: stripHeight)
    }
    var activityWingWidth: CGFloat { max(0, (activityStrip.width - cameraWidth) / 2) }

    /// Only a physical camera may need a footer. A simulated cutout and all
    /// of its compact activity stay within the real menu bar's height.
    var compactActivityUsesFooter: Bool { isNotched && allowsActivityFooter && activityWingWidth < 44 }
    var compactActivityContentHeight: CGFloat { compactActivityUsesFooter ? 32 : stripHeight }
    var compactActivityTopPadding: CGFloat { compactActivityUsesFooter ? stripHeight : 0 }
    var compactActivityHorizontalPadding: CGFloat { compactActivityUsesFooter ? 4 : 0 }
    var compactActivityCameraGap: CGFloat { compactActivityUsesFooter ? 0 : cameraWidth }
    var compactActivitySize: CGSize {
        compactActivityUsesFooter
            ? CGSize(width: cameraWidth, height: compactActivityTopPadding + compactActivityContentHeight)
            : activityStrip
    }
    var compactActivityWingWidth: CGFloat {
        max(0, (compactActivitySize.width - compactActivityCameraGap - compactActivityHorizontalPadding * 2) / 2)
    }
    /// Where the silhouette's straight edge sits, once its shoulder has flared.
    var compactActivityShoulder: CGFloat {
        NotchLayout.shoulder(height: compactActivitySize.height)
    }
    /// Inset that keeps a vertically centred box of `boxHeight`, itself rounded
    /// by `radius`, an even `gap` away from the strip's silhouette.
    /// A strip is barely taller than its corners, so its lower half is one long
    /// arc: padding measured against the straight edge still leaves artwork and
    /// meters grazing the curve. Push the box in until its own corner keeps the
    /// same distance from the arc that its top keeps from the shoulder.
    func compactActivityEdgeInset(boxHeight: CGFloat, radius: CGFloat,
                                  gap: CGFloat = NotchLayout.compactEdgeGap) -> CGFloat {
        let shoulder = compactActivityShoulder
        let corner = min(NotchLayout.surfaceRadius(height: compactActivitySize.height),
                         (compactActivitySize.width - shoulder * 2) / 2)
        let flat = shoulder + gap - compactActivityHorizontalPadding
        let below = (compactActivityContentHeight - boxHeight) / 2
        // Both corner centres, grown by the gap, decide the horizontal offset.
        let reach = corner - radius - gap
        let drop = corner - radius - below
        guard reach > 0, drop > 0 else { return max(0, flat) }
        let span = reach > drop ? (reach * reach - drop * drop).squareRoot() : 0
        return max(0, flat, shoulder + corner - radius - span - compactActivityHorizontalPadding)
    }
    var notice: CGSize {
        noticeSize(wingWidth: 80)
    }
    var noticeCameraGap: CGFloat { cameraWidth }

    func noticeSize(wingWidth: CGFloat) -> CGSize {
        CGSize(width: min(screen.width - 24, noticeCameraGap + wingWidth * 2), height: stripHeight)
    }

    func noticeWingWidth(preferred: CGFloat) -> CGFloat {
        max(0, (noticeSize(wingWidth: preferred).width - noticeCameraGap) / 2)
    }

    /// Each side as wide as it asks, short of the display's edge.
    func noticeWings(_ preferred: NotchNoticeWings) -> NotchNoticeWings {
        NotchNoticeWings(leading: noticeWingWidth(preferred: preferred.leading),
                         trailing: noticeWingWidth(preferred: preferred.trailing))
    }

    func noticeSize(wings preferred: NotchNoticeWings) -> CGSize {
        let wings = noticeWings(preferred)
        return CGSize(width: noticeCameraGap + wings.leading + wings.trailing, height: stripHeight)
    }

    /// How far a notice's centre sits from the camera's, toward its wider side.
    func noticeShift(_ preferred: NotchNoticeWings) -> CGFloat {
        let wings = noticeWings(preferred)
        return (wings.trailing - wings.leading) / 2
    }
    var peek: CGSize {
        CGSize(width: min(screen.width - 24, max(cameraWidth + 110, 340)), height: safeContentTop + 52)
    }
    var expanded: CGSize { expandedSize(module: .controls) }
    var expandedWidth: CGFloat {
        let chosen = NotchLayout.preferredWidth(layout, custom: customWidth)
        // Under a preset, a page with a width of its own takes no more, still
        // wrapping the camera with its row where the chosen width would have.
        // Each side keeps its room for the page's controls past the sections
        // button, as the camera's sides are as wide as each other. A width
        // set by hand is the island's on every page, so making it wider
        // makes the home page wider too.
        let wing = Self.pageBandSide + (sectionsButtonInRow ? NotchBand.sectionsButtonRoom : 0)
        let preferred = layout == .custom ? chosen : pageContentWidth.map { natural in
            min(chosen, max(natural, isNotched ? cameraWidth + wing * 2 : 0) + NotchLayout.horizontalInset * 2)
        } ?? chosen
        return min(max(preferred, cameraWidth + 36), screen.width - 24 - NotchQuickAccessLayout.gutter * 2)
    }
    var contentWidth: CGFloat { max(0, expandedWidth - NotchLayout.horizontalInset * 2) }
    /// Content height available before a page needs to scroll.
    var contentBudget: CGFloat {
        switch layout {
        case .compact: return NotchLayout.compactContentHeight
        case .spacious: return NotchLayout.spaciousContentHeight
        case .custom: return max(0, customHeight - headerTopInset - headerChromeHeight)
        }
    }
    /// Room a vertical surface gets: the budget, or a readable page where a
    /// preset's strip would leave it a few lines.
    var pageBudget: CGFloat { layout == .custom ? contentBudget : max(contentBudget, NotchLayout.pageContentHeight) }

    func systemRows(cards: Int) -> Int {
        NotchLayout.systemRowRanges(count: cards, width: contentWidth - NotchLayout.systemHoverInset(width: contentWidth) * 2).count
    }

    /// `detailHeight` is a detail's measured content, which it fits instead
    /// of the whole page.
    func expandedSize(module: NotchModule, detail: Bool = false, panel: Bool = false,
                      detailHeight: CGFloat? = nil, shortcutCount: Int = 4, systemCards: Int = 6,
                      agentsHeight: CGFloat? = nil) -> CGSize {
        let budget = contentBudget
        let contentHeight: CGFloat
        if detail, !panel, let detailHeight {
            contentHeight = min(pageBudget, max(0, detailHeight) + 4)
        } else if detail || panel {
            contentHeight = pageBudget
        } else {
            switch module {
            case .controls:
                // The shortcuts make the page.
                let home = NotchLayout.controls(shortcutCount: max(0, shortcutCount), width: contentWidth, height: budget)
                contentHeight = min(budget, shortcutCount <= 0 ? NotchLayout.emptyHeight : home.height)
            case .system:
                let cards = max(0, systemCards)
                contentHeight = min(budget, cards == 0 ? NotchLayout.emptyHeight
                    : NotchLayout.railHeight(rows: systemRows(cards: cards), rowHeight: NotchLayout.systemCardHeight, spacing: NotchLayout.rowSpacing)
                        + NotchLayout.systemHoverInset(width: contentWidth) * 2)
            case .agents:
                // Only the cards a person chose; a short set leaves a short island.
                contentHeight = min(budget, agentsHeight.map { $0 > 0 ? $0 : NotchLayout.emptyHeight } ?? budget)
            // The clipboard's list fills the chosen content budget.
            case .clipboard:
                contentHeight = budget
            }
        }
        var preferredHeight = headerTopInset + headerChromeHeight + contentHeight
        if layout == .custom { preferredHeight = min(preferredHeight, customHeight) }
        return CGSize(width: expandedWidth,
                      height: min(preferredHeight, screen.height - 48 - quickAccessBottomInset))
    }

    /// Leave room for the row indicator without narrowing the tiles below
    /// their readable width. Keyboard navigation uses these same columns.
    var sectionColumns: Int {
        NotchLayout.railCapacity(width: contentWidth - NotchLayout.sectionIndicatorWidth, itemWidth: NotchLayout.sectionTileWidth,
                                 spacing: NotchLayout.sectionSpacing)
    }

    /// Visible rows. The gallery is a page like the app panel, so a preset
    /// shows three rows before any row has to step in; the rest step in whole.
    func sectionRows(count: Int) -> Int {
        NotchLayout.railRows(count: count,
                             perRow: sectionColumns,
                             rowHeight: NotchLayout.sectionTileHeight, spacing: NotchLayout.sectionSpacing, height: pageBudget)
    }

    func sectionPickerSize(count: Int) -> CGSize {
        let content = min(pageBudget, count == 0 ? NotchLayout.emptyHeight
            : NotchLayout.railHeight(rows: sectionRows(count: count), rowHeight: NotchLayout.sectionTileHeight, spacing: NotchLayout.sectionSpacing))
        let desiredHeight = headerTopInset + headerChromeHeight + content
        return CGSize(width: expandedWidth, height: min(desiredHeight, screen.height - 48 - quickAccessBottomInset))
    }

    func contentSize(for size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width - NotchLayout.horizontalInset * 2),
               height: max(0, size.height - headerTopInset - headerChromeHeight))
    }
    func frame(for size: CGSize) -> CGRect {
        CGRect(x: screen.midX + surfaceShift - size.width / 2,
               y: screen.maxY - floatingDrop - size.height,
               width: size.width, height: size.height)
    }

    func contains(_ point: CGPoint, in size: CGSize) -> Bool {
        let frame = self.frame(for: size)
        // Match the flipped native view: the top edge belongs to the island.
        return CGRect(origin: .zero, size: size).contains(
            CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
    }
}

struct NotchSessionState {
    var locked = false
    var sleeping = false
    var displaysSleeping = false
    var onConsole = true
    /// Only the lock screen gives way to a screen saver, which it would
    /// otherwise float over; the island keeps its own rules.
    var screenSaverRunning = false
    var canPresent: Bool { !locked && !sleeping && onConsole && !displaysSleeping }
    /// The lock screen itself is on screen, awake and in front of this user.
    var showsLockScreen: Bool { locked && !sleeping && onConsole && !displaysSleeping && !screenSaverRunning }
    /// Someone is at the Mac to hear it lock or unlock, rather than closing
    /// the lid or leaving it to a screen saver or to fall asleep.
    var hearsLockChange: Bool { !sleeping && onConsole && !displaysSleeping && !screenSaverRunning }
}

/// Reserve enough backing space for both ends. The visible silhouette moves
/// inside it; the native window only shrinks after the transition finishes.
///
/// Each side follows its own spring, as the phone's island does. Growing, the
/// island drops a little ahead of widening and passes its size before it
/// settles; shrinking, it pulls up ahead of narrowing and never passes its
/// target, which for a resting island is the camera it hugs.
enum NotchMotion {
    /// Departing content has faded out by 0.16 s; the view then swaps it for
    /// the next content, which fades in once the swap is on screen.
    static let departureHidden: TimeInterval = 0.2

    struct Spring: Equatable {
        /// Perceptual duration and bounce, as SwiftUI and Core Animation define them.
        var duration: TimeInterval
        var bounce: Double

        /// Progress from rest at 0 toward 1.
        func progress(at time: TimeInterval) -> Double {
            guard time > 0 else { return 0 }
            let natural = 2 * Double.pi / duration
            let damping = 1 - bounce
            if damping >= 1 { return 1 - exp(-natural * time) * (1 + natural * time) }
            let damped = natural * (1 - damping * damping).squareRoot()
            return 1 - exp(-damping * natural * time)
                * (cos(damped * time) + damping * natural / damped * sin(damped * time))
        }

        /// How far past the target the spring swings, as a share of its travel.
        var overshoot: Double {
            guard bounce > 0 else { return 0 }
            let damping = 1 - bounce
            return exp(-Double.pi * damping / (1 - damping * damping).squareRoot())
        }

        /// This spring, with only as much bounce as keeps the swing within `limit` points.
        func limited(travel: CGFloat, limit: CGFloat) -> Spring {
            guard bounce > 0, travel > 0, Double(travel) * overshoot > Double(limit) else { return self }
            let share = log(Double(max(limit, 0.01) / travel))
            return Spring(duration: duration, bounce: 1 + share / (Double.pi * Double.pi + share * share).squareRoot())
        }
    }

    static let growingWidth = Spring(duration: 0.44, bounce: 0.25)
    static let growingHeight = Spring(duration: 0.38, bounce: 0.22)
    static let shrinkingWidth = Spring(duration: 0.30, bounce: 0)
    static let shrinkingHeight = Spring(duration: 0.26, bounce: 0)
    /// A strip that stays on screen and only fits a new reading, as a level
    /// passing 99% or 9%, eases to its width without a swing, either way.
    static let steadyWidth = Spring(duration: 0.5, bounce: 0)
    /// The farthest a side may pass its target. The display always keeps at
    /// least this much free around the island and its floating controls.
    static let overshootLimit: CGFloat = 12
    /// Sides closer than this to their targets read as settled.
    static let settledDistance: CGFloat = 0.5

    static func spring(from: CGFloat, to: CGFloat, width: Bool, steady: Bool = false) -> Spring {
        if steady && width { return steadyWidth }
        let spring = to > from ? (width ? growingWidth : growingHeight) : (width ? shrinkingWidth : shrinkingHeight)
        return spring.limited(travel: abs(to - from), limit: overshootLimit)
    }

    /// The spring carrying the island's sides, for controls that ride along them.
    static func sideSpring(from: CGSize, to: CGSize) -> Spring {
        from.width != to.width ? spring(from: from.width, to: to.width, width: true)
            : spring(from: from.height, to: to.height, width: false)
    }

    /// The perceptual duration of the slower side that moves.
    static func duration(from: CGSize, to: CGSize) -> TimeInterval {
        var durations: [TimeInterval] = []
        if from.width != to.width { durations.append(spring(from: from.width, to: to.width, width: true).duration) }
        if from.height != to.height { durations.append(spring(from: from.height, to: to.height, width: false).duration) }
        return durations.max() ?? growingWidth.duration
    }

    static func size(at time: TimeInterval, from: CGSize, to: CGSize, steady: Bool = false) -> CGSize {
        func side(_ start: CGFloat, _ end: CGFloat, width: Bool) -> CGFloat {
            guard start != end else { return end }
            let spring = spring(from: start, to: end, width: width, steady: steady)
            return max(0, start + (end - start) * CGFloat(spring.progress(at: time)))
        }
        return CGSize(width: side(from.width, to.width, width: true), height: side(from.height, to.height, width: false))
    }

    /// When every side that moves first comes within 1% of its travel from
    /// its target: the island has arrived, though it may still swing.
    static func arrivalTime(from: CGSize, to: CGSize) -> TimeInterval {
        let sides = [(from.width, to.width, true), (from.height, to.height, false)].filter { $0.0 != $0.1 }
        let step = 1.0 / 240
        var time = step
        while time < 2, !sides.allSatisfy({ spring(from: $0.0, to: $0.1, width: $0.2).progress(at: time) >= 0.99 }) {
            time += step
        }
        return sides.isEmpty ? 0 : time
    }

    /// When the size and centre stay within `settledDistance` of their targets for good.
    static func settlingTime(from: CGSize, to: CGSize, steady: Bool = false, offset startOffset: CGFloat = 0) -> TimeInterval {
        let step = 1.0 / 240
        var settled = step
        var time = step
        while time < 2 {
            let size = size(at: time, from: from, to: to, steady: steady)
            let offset = offset(at: time, from: from, to: to, start: startOffset, steady: steady)
            if abs(size.width - to.width) > settledDistance || abs(size.height - to.height) > settledDistance
                || abs(offset) > settledDistance {
                settled = time + step
            }
            time += step
        }
        return settled
    }

    /// How far a moving island's centre still sits from its new one. It
    /// travels with the width's spring, or eases on its own when two notices
    /// have the same total width but different sides.
    static func offset(at time: TimeInterval, from: CGSize, to: CGSize, start: CGFloat, steady: Bool = false) -> CGFloat {
        guard start != 0 else { return 0 }
        let spring = from.width == to.width ? steadyWidth : spring(from: from.width, to: to.width, width: true, steady: steady)
        return start * CGFloat(1 - spring.progress(at: time))
    }

    /// Sizes at a steady rate, ending exactly at `to`, and where each falls
    /// within the duration, including a centre still on its way there.
    static func frames(from: CGSize, to: CGSize,
                       steady: Bool = false, offset: CGFloat = 0) -> (sizes: [CGSize], keyTimes: [Double], duration: TimeInterval) {
        let duration = settlingTime(from: from, to: to, steady: steady, offset: offset)
        let count = max(1, Int((duration * 120).rounded(.up)))
        let keyTimes = (0...count).map { Double($0) / Double(count) }
        let sizes = keyTimes.map { $0 == 1 ? to : size(at: duration * $0, from: from, to: to, steady: steady) }
        return (sizes, keyTimes, duration)
    }

    /// Whole, equal margins around `size`, so the island keeps its exact
    /// pixels when the window returns to that size; half a point would round
    /// to a one-pixel jump on a standard-resolution display.
    static func reservation(_ reserved: CGSize, centring size: CGSize) -> CGSize {
        CGSize(width: size.width + 2 * max(0, (reserved.width - size.width) / 2).rounded(.up),
               height: max(reserved.height, size.height))
    }

    static func envelope(from: CGSize, to: CGSize) -> CGSize {
        func side(_ start: CGFloat, _ end: CGFloat, width: Bool) -> CGFloat {
            let swing = end > start ? spring(from: start, to: end, width: width).overshoot : 0
            guard swing > 0 else { return max(start, end) }
            return (end + (end - start) * CGFloat(swing)).rounded(.up)
        }
        return CGSize(width: side(from.width, to.width, width: true), height: side(from.height, to.height, width: false))
    }
}

/// A resize in flight, each side a sum of the island's springs from rest: the
/// move it began with, and one more from each moment that side's target moved
/// on the way it was already going. The island then carries on at its speed;
/// started again from rest it stalled halfway, as the Command Bar's island did
/// when its rows arrived while it opened. A motion turning back on either side
/// starts again from where it is drawn, as an interrupted island always has.
struct NotchMotionTimeline: Equatable {
    struct Leg: Equatable {
        var begin: CFTimeInterval
        var from: CGFloat
        var to: CGFloat
    }

    private(set) var width: [Leg]
    private(set) var height: [Leg]
    /// When its latest move began, and the size there.
    private(set) var begin: CFTimeInterval
    private(set) var start: CGSize
    /// A width easing without a swing, and how far the centre still sat from
    /// its new one. A motion with either is never carried on.
    let steady: Bool
    let offset: CGFloat

    init(from: CGSize, to: CGSize, begin: CFTimeInterval, steady: Bool = false, offset: CGFloat = 0) {
        width = [Leg(begin: begin, from: from.width, to: to.width)]
        height = [Leg(begin: begin, from: from.height, to: to.height)]
        self.begin = begin
        start = from
        self.steady = steady
        self.offset = offset
    }

    var target: CGSize { CGSize(width: width.last?.to ?? start.width, height: height.last?.to ?? start.height) }

    func size(at time: CFTimeInterval) -> CGSize {
        CGSize(width: value(of: width, at: time, width: true), height: value(of: height, at: time, width: false))
    }

    func offset(at time: CFTimeInterval) -> CGFloat {
        NotchMotion.offset(at: time - begin, from: start, to: target, start: offset, steady: steady)
    }

    /// The same motion with its latest move beginning at `time`: Core
    /// Animation starts a motion when it reaches the screen, not when it is made.
    func rebased(to time: CFTimeInterval) -> NotchMotionTimeline {
        func moved(_ legs: [Leg]) -> [Leg] {
            legs.map { $0.begin == begin ? Leg(begin: time, from: $0.from, to: $0.to) : $0 }
        }
        var rebased = self
        rebased.width = moved(width)
        rebased.height = moved(height)
        rebased.begin = time
        return rebased
    }

    /// This motion headed for `size` from `time` on, or nil when a side turns
    /// back, or the motion eases without a swing or moves its centre.
    func continued(to size: CGSize, at time: CFTimeInterval) -> NotchMotionTimeline? {
        guard !steady, offset == 0, let width = continued(width, to: size.width, at: time),
              let height = continued(height, to: size.height, at: time) else { return nil }
        var next = self
        next.width = width
        next.height = height
        next.begin = time
        next.start = self.size(at: time)
        return next
    }

    /// Sizes at a steady rate from its latest move until every side stays
    /// within `settledDistance` of its target, ending exactly there.
    func frames() -> (sizes: [CGSize], keyTimes: [Double], duration: TimeInterval) {
        let target = target
        let step = 1.0 / 240
        var duration = step
        var time = step
        while time < 2 {
            let size = size(at: begin + time)
            if abs(size.width - target.width) > NotchMotion.settledDistance
                || abs(size.height - target.height) > NotchMotion.settledDistance {
                duration = time + step
            }
            time += step
        }
        let count = max(1, Int((duration * 120).rounded(.up)))
        let keyTimes = (0...count).map { Double($0) / Double(count) }
        let sizes = keyTimes.map { $0 == 1 ? target : size(at: begin + duration * $0) }
        return (sizes, keyTimes, duration)
    }

    private func value(of legs: [Leg], at time: CFTimeInterval, width: Bool) -> CGFloat {
        guard let first = legs.first, let last = legs.last else { return 0 }
        let value = legs.reduce(first.from) { value, leg in
            guard leg.from != leg.to else { return value }
            let spring = NotchMotion.spring(from: leg.from, to: leg.to, width: width, steady: steady)
            return value + (leg.to - leg.from) * CGFloat(spring.progress(at: time - leg.begin))
        }
        // Swings that happen to coincide still pass the target no further
        // than one does, so the display keeps its free margin.
        return max(0, min(value, max(first.from, last.to) + NotchMotion.overshootLimit))
    }

    private func continued(_ legs: [Leg], to end: CGFloat, at time: CFTimeInterval) -> [Leg]? {
        guard let last = legs.last, end != last.to else { return legs }
        let heading = legs.first { $0.from != $0.to }.map { $0.to - $0.from } ?? 0
        guard heading == 0 || (end > last.to) == (heading > 0) else { return nil }
        return legs + [Leg(begin: time, from: last.to, to: end)]
    }
}

/// How open the glass lip is at each height of a resize. The page leaves the
/// island as soon as it starts closing, so glass closing into a black strip
/// shuts at once: open, the empty glass showed the windows beneath it through
/// the whole collapse. Glass leaving a black strip stays shut until the last
/// stretch, where the page fades in over it. An opening that interrupts a
/// close starts from the openness already on screen.
struct NotchGlassFade: Equatable {
    /// Where the lip is shut, and the height over which it opens from there.
    var solidHeight: CGFloat = 0
    var range: CGFloat = 1

    static let open = NotchGlassFade()
    static let stretch: CGFloat = 48

    func openness(atHeight height: CGFloat) -> CGFloat {
        guard height.isFinite, range > 0 else { return 1 }
        return min(1, max(0, (height - solidHeight) / range))
    }

    /// `current` is the openness on screen at `start`: zero while black.
    static func plan(from start: CGFloat, to end: CGFloat, endsInGlass: Bool, current: CGFloat) -> NotchGlassFade {
        guard start.isFinite, end.isFinite else { return .open }
        let current = min(1, max(0, current.isFinite ? current : 1))
        let travel = abs(end - start)
        if endsInGlass {
            guard end > start, current < 1 else { return .open }
            if current == 0 {
                let range = min(stretch, travel)
                return NotchGlassFade(solidHeight: end - range, range: max(1, range))
            }
            let range = travel / (1 - current)
            return NotchGlassFade(solidHeight: start - current * range, range: max(1, range))
        }
        return NotchGlassFade(solidHeight: max(start, end), range: 1)
    }
}

/// Free room on both sides of the camera, in Cocoa screen coordinates.
/// Unknown/occupied camera space is distinct from a known zero-width wing.
enum NotchMenuBarLayout {
    /// A successful AX read can contain menu items from another display.
    /// Without an item on this display, its menu space remains unknown.
    static func measuredSideRoom(screen: CGRect, cameraWidth: CGFloat, barHeight: CGFloat,
                                 menuItems: [CGRect], statusItems: [CGRect]) -> CGFloat? {
        let bar = CGRect(x: screen.minX, y: screen.maxY - barHeight, width: screen.width, height: barHeight)
        guard menuItems.contains(where: { $0.intersects(bar) }) else { return nil }
        return sideRoom(screen: screen, cameraWidth: cameraWidth, barHeight: barHeight,
                        occupied: menuItems + statusItems)
    }

    static func sideRoom(screen: CGRect, cameraWidth: CGFloat, barHeight: CGFloat,
                         occupied: [CGRect]) -> CGFloat? {
        let bar = CGRect(x: screen.minX, y: screen.maxY - barHeight, width: screen.width, height: barHeight)
        let camera = CGRect(x: screen.midX - cameraWidth / 2, y: bar.minY,
                            width: cameraWidth, height: barHeight)
        var left = screen.minX + 8
        var right = screen.maxX - 8
        for rect in occupied where rect.intersects(bar) {
            guard rect.minX.isFinite, rect.maxX.isFinite, rect.width > 0 else { return nil }
            if rect.intersects(camera) { return nil }
            if rect.maxX <= camera.minX { left = max(left, rect.maxX + 8) }
            if rect.minX >= camera.maxX { right = min(right, rect.minX - 8) }
        }
        return max(0, min(camera.minX - left, right - camera.maxX))
    }
}

/// The black tint over the open island's translucent background, measured in
/// points from the top: fully black over the camera strip at every island
/// height (the hover preview is only the strip plus 62 points), then easing
/// toward the translucent body.
enum NotchTranslucentTint {
    static let rampLength: CGFloat = 36

    static func opacity(atDepth depth: CGFloat, stripHeight: CGFloat,
                        openness: Double, increasedContrast: Bool) -> Double {
        guard depth > stripHeight else { return 1 }
        let ramp = Double(min(1, (depth - stripHeight) / rampLength))
        let eased = ramp * ramp * (3 - 2 * ramp)
        return 1 - min(1, max(0, openness)) * (increasedContrast ? 0.3 : 0.62) * eased
    }

    /// Gradient stops over an island `height` points tall, top to bottom.
    static func stops(height: CGFloat, stripHeight: CGFloat, openness: Double,
                      increasedContrast: Bool) -> [(location: Double, opacity: Double)] {
        guard height > 0 else { return [(0, 1), (1, 1)] }
        let depths = [0, stripHeight] + (1...8).map { stripHeight + rampLength * CGFloat($0) / 8 } + [height]
        return depths.filter { $0 >= 0 && $0 <= height }.map {
            (Double($0 / height), opacity(atDepth: $0, stripHeight: stripHeight,
                                          openness: openness, increasedContrast: increasedContrast))
        }
    }
}

/// How the island folds a typed search and the titles it is matched against.
enum NotchSearch {
    /// Case, accent and width differences never matter. Folded without a
    /// locale on purpose: Turkish lowercases a capital I to a dotless one, so
    /// a locale-aware fold would stop a search from finding a title that
    /// begins with that letter on a Mac set to Turkish.
    static func normalized(_ value: String) -> String {
        let folded = strippingInvisibles(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
            .lowercased()
        // Splitting on any whitespace — not just the ASCII space — treats the
        // full-width space (U+3000) that some input methods produce the same
        // as the half-width one, so "bd　123" folds like "bd 123".
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Drops the characters that take up no space and that nobody can type:
    /// direction marks, zero-width joiners, soft hyphens. A single invisible
    /// character is enough to stop a title from matching its own name.
    private static func strippingInvisibles(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: isInvisible) else { return value }
        return String(String.UnicodeScalarView(value.unicodeScalars.filter { !isInvisible($0) }))
    }

    /// Every format character sits above this point, so plain text never pays
    /// for the lookup.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x00AD && scalar.properties.generalCategory == .format
    }
}
