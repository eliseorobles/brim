// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// A running Keep Awake session as a live activity of the closed island, for
/// those who turn it on. With the island standing in for the menu bar glyph,
/// it is the one sign left that the Mac is being kept awake.
enum NotchKeepAwakeSupport {
    /// The mark of the island's Keep Awake tile, filled as the active tile is.
    static let symbol = "cup.and.saucer.fill"
    /// Where a timed session shows its time left, one without an end shows this.
    static let openSymbol = "infinity"

    static func showsActivity(in defaults: UserDefaults = .standard) -> Bool {
        NotchSupport.isEnabled(in: defaults) && AppFeature.keepAwake.isAvailable(in: defaults)
            && defaults.bool(forKey: DefaultsKey.notchKeepAwakeActivity)
    }

    /// Whole minutes left, rounded up: a new half-hour session reads 30m, and
    /// its last minute still reads 1m until the session ends.
    static func minutesLeft(until end: Date, now: Date) -> Int {
        let minutes = (end.timeIntervalSince(now) / 60).rounded(.up)
        guard minutes.isFinite else { return 1 }
        return Int(min(Double(Int32.max), max(1, minutes)))
    }

    /// "45m" under an hour, then "1h35", never "1:35", which would pass for
    /// one minute and thirty five seconds.
    static func compactText(until end: Date, now: Date, locale: Locale) -> String {
        let minutes = minutesLeft(until: end, now: now)
        guard minutes >= 60 else {
            return Duration.seconds(minutes * 60).formatted(.units(
                allowed: [.minutes], width: .narrow, fractionalPart: .hide(rounded: .down)).locale(locale))
        }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    /// The minute boundary the reading last crossed. A schedule that ticks
    /// once a minute from there wakes exactly when the reading changes.
    static func tickStart(until end: Date, now: Date) -> Date {
        end.addingTimeInterval(-TimeInterval(minutesLeft(until: end, now: now)) * 60)
    }

    // MARK: Strip

    /// A wing is never narrower than an idle strip's; the longest readings
    /// keep the width the strip always had.
    static let stripWingRange: ClosedRange<CGFloat> = 44...64
    /// Air between the camera and what sits beside it.
    static let stripCameraGap: CGFloat = 6

    static func stripTextSize(height: CGFloat) -> CGFloat { min(16, height - 6) }
    /// The mark takes the strip's height less an even gap above and below.
    static func stripIconSize(height: CGFloat) -> CGFloat { min(20, height - NotchLayout.compactEdgeGap * 2) }

    /// The wider of the two sides, the cup or the time left, drawn as the
    /// strip draws them, with clearance from the silhouette's curve and air
    /// beside the camera.
    static func stripWing(until end: Date?, now: Date, locale: Locale, in geometry: NotchGeometry) -> CGFloat {
        let provisional = geometry.compactKeepAwakeGeometry(wing: stripWingRange.lowerBound)
        let height = provisional.compactActivityContentHeight
        let textSize = stripTextSize(height: height)
        let reading = end.map {
            (NotchAgentSupport.readingShape(compactText(until: $0, now: now, locale: locale)) as NSString)
                .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .medium)])
                .width.rounded(.up)
        } ?? symbolWidth(openSymbol, size: textSize)
        let iconSize = stripIconSize(height: height)
        let mark = symbolWidth(symbol, size: iconSize)
            + provisional.compactActivityEdgeInset(boxHeight: iconSize, radius: iconSize / 2)
        return max(reading + provisional.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0), mark)
            + stripCameraGap
    }

    /// Symbols draw wider than their point size. The island asks for its
    /// geometry on every layout, so each one is measured once per size.
    private static var measuredSymbols: [String: CGFloat] = [:]

    static func symbolWidth(_ name: String, size: CGFloat) -> CGFloat {
        let key = "\(name) \(size)"
        if let width = measuredSymbols[key] { return width }
        let width = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))?
            .size.width.rounded(.up) ?? size
        measuredSymbols[key] = width
        return width
    }
}
