// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreGraphics

enum NotchLockScreenSupport {
    /// The Space level macOS gives the notifications it shows over the lock
    /// screen, one step above the lock screen's own 300. A window in a Space
    /// at this level is drawn over the lock screen; the same window without
    /// it, even at the shielding window level, stays behind it.
    static let spaceLevel: Int32 = 400

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        NotchSupport.isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchLockScreen)
    }

    static func playsSounds(in defaults: UserDefaults = .standard) -> Bool {
        NotchSupport.isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchLockSounds)
    }

    /// The padlock sounds macOS plays in its own settings. A release that
    /// moves them falls back to alert sounds rather than going quiet.
    static func soundURL(locking: Bool, fileManager: FileManager = .default) -> URL? {
        if let padlock = Bundle(path: "/System/Library/Frameworks/SecurityInterface.framework")?
            .url(forResource: locking ? "lock" : "unlock", withExtension: "aif") {
            return padlock
        }
        let alert = URL(fileURLWithPath: "/System/Library/Sounds/\(locking ? "Tink" : "Pop").aiff")
        return fileManager.fileExists(atPath: alert.path) ? alert : nil
    }
}

/// macOS draws the lock screen's date, clock and login controls in one window
/// over the whole display, so their room is kept by measure. On macOS 26 and
/// 27 the date and clock end 236 points from the top of a 956-point display,
/// and the name, picture, password field and hint take the lowest 218.
/// The working agents read as a line under the clock, where a phone keeps
/// its lock screen widgets.
enum NotchLockScreenLayout {
    /// A taller display draws a larger clock.
    static func clockBottom(screenHeight: CGFloat) -> CGFloat { max(236, screenHeight * 0.247) }
    static let rowGap: CGFloat = 18
    static let rowHeight: CGFloat = 30
    /// From the bottom of the display to the login controls' top.
    static let loginClearance: CGFloat = 250
    /// The padlock's side of the locked island, as wide as a wing of the
    /// island at rest, so the island keeps its size as the Mac locks.
    static let islandWing: CGFloat = 44

    private static func readable(_ screen: CGRect) -> Bool {
        [screen.minX, screen.minY, screen.width, screen.height].allSatisfy(\.isFinite)
            && screen.width > 64 && screen.height > 0
    }

    /// The line of activities under the clock.
    static func rowFrame(in screen: CGRect) -> CGRect? {
        guard readable(screen) else { return nil }
        let width = min(screen.width - 64, 1000)
        let top = screen.maxY - clockBottom(screenHeight: screen.height) - rowGap
        guard top - rowHeight >= screen.minY + loginClearance else { return nil }
        return CGRect(x: (screen.midX - width / 2).rounded(), y: top - rowHeight, width: width, height: rowHeight)
    }

    /// The locked island hung from the top of `screen`, around its camera,
    /// with a `wing` on each side: the padlock in the first. It is the
    /// camera's exact fitted height, as the closed strips keep it: a half
    /// point more would show as a dark line under the housing.
    static func islandSurface(in screen: CGRect, cameraWidth: CGFloat, cameraHeight: CGFloat, wing: CGFloat) -> CGRect? {
        guard [screen.width, screen.height, cameraWidth, cameraHeight, wing].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let width = min(screen.width - 24, cameraWidth + wing * 2)
        guard width > cameraWidth else { return nil }
        // Centred on the camera to the half point: a notch only comes on Retina displays.
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - cameraHeight, width: width, height: cameraHeight)
    }

    /// The island's window. The lock screen's windows land on whole points,
    /// so it grows out to them around the island, which keeps its own size
    /// at the top of the window and leaves the extra room clear.
    static func islandFrame(around surface: CGRect) -> CGRect { surface.integral }
}
