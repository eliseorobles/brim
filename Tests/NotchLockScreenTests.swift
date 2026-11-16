// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// When the lock screen shows the island's agents, the room it keeps for
/// the system's clock and login controls, and what gives way on a short
/// display. Nothing here locks the Mac or opens a window.
enum NotchLockScreenTests {
    static func run(_ suite: TestSuite) {
        sessionContracts(suite)
        preferenceContracts(suite)
        layoutContracts(suite)
        soundContracts(suite)
    }

    static func sessionContracts(_ suite: TestSuite) {
        var locked = NotchSessionState()
        suite.expect(!locked.showsLockScreen, "an unlocked Mac shows nothing over its lock screen")
        locked.locked = true
        suite.expect(locked.showsLockScreen && !locked.canPresent,
                     "locked with the display awake, the lock screen takes over from the island")
        let hidden: [(WritableKeyPath<NotchSessionState, Bool>, String)] = [
            (\.sleeping, "the Mac asleep"), (\.displaysSleeping, "the display asleep"),
            (\.screenSaverRunning, "a screen saver running"),
        ]
        for (change, reason) in hidden {
            var session = locked
            session[keyPath: change] = true
            suite.expect(!session.showsLockScreen, "nothing shows with \(reason)")
        }
        var switched = locked
        switched.onConsole = false
        suite.expect(!switched.showsLockScreen, "nothing shows while another user has the display")
        var saver = NotchSessionState()
        saver.screenSaverRunning = true
        suite.expect(saver.canPresent, "a screen saver alone leaves the island as it was")
        suite.expect(NotchSessionState().hearsLockChange && locked.hearsLockChange,
                     "a lock or unlock at the keyboard is heard")
        var closing = NotchSessionState()
        closing.sleeping = true
        var dark = NotchSessionState()
        dark.displaysSleeping = true
        suite.expect(!closing.hearsLockChange && !dark.hearsLockChange && !switched.hearsLockChange,
                     "closing the lid, a dark display or a switched user plays no padlock")
        suite.expect(!saver.hearsLockChange, "a lock that follows an idle screen saver plays no padlock")
    }

    static func preferenceContracts(_ suite: TestSuite) {
        suite.expect(Defaults.registeredDefaults[DefaultsKey.notchLockScreen] as? Bool == false
                     && Defaults.registeredDefaults[DefaultsKey.notchLockSounds] as? Bool == false,
                     "the lock screen and its sounds are both opt-in")
        let domain = "brim.tests.notch-lock-screen"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { defaults.set(value, forKey: key) }
        for (key, value) in AppFeature.availabilityDefaults { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: DefaultsKey.notchLockScreen)
        defaults.set(true, forKey: DefaultsKey.notchLockSounds)
        defaults.set(false, forKey: DefaultsKey.notchEnabled)
        suite.expect(!NotchLockScreenSupport.isEnabled(in: defaults) && !NotchLockScreenSupport.playsSounds(in: defaults),
                     "the island's own switch turns off the lock screen and the sounds")
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        suite.expect(NotchLockScreenSupport.isEnabled(in: defaults) && NotchLockScreenSupport.playsSounds(in: defaults),
                     "with the island on, each follows its own switch")
        defaults.set(false, forKey: DefaultsKey.notchLockScreen)
        suite.expect(!NotchLockScreenSupport.isEnabled(in: defaults) && NotchLockScreenSupport.playsSounds(in: defaults),
                     "the sounds do not need the lock screen")
    }

    static func layoutContracts(_ suite: TestSuite) {
        typealias Layout = NotchLockScreenLayout
        // Measured on the lock screen of a 1470 by 956 point display: the
        // clock ends 236 points from the top, the login controls take 218.
        let measured = CGRect(x: 0, y: 0, width: 1470, height: 956)
        if let row = Layout.rowFrame(in: measured) {
            suite.expect(measured.maxY - row.maxY >= 236 + 12 && measured.maxY - row.maxY <= 236 + 30,
                         "the agents read as a line just under the clock")
            suite.expect(row.minY - measured.minY >= 218 + 24, "the line clears the name, picture, password field and hint")
            suite.expect(abs(row.midX - measured.midX) <= 0.5, "the line stands centered under the clock")
        } else {
            suite.expect(false, "the measured display has room for the line under the clock")
        }
        let displays = [
            CGRect(x: 0, y: 0, width: 1280, height: 800), CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: 1470, y: -86, width: 1920, height: 1080),
            CGRect(x: -2560, y: 0, width: 2560, height: 1440), CGRect(x: 0, y: 0, width: 3008, height: 1692),
            CGRect(x: 0, y: 1117, width: 1080, height: 1920),
        ]
        for display in displays {
            guard let row = Layout.rowFrame(in: display) else {
                suite.expect(false, "a \(Int(display.width))x\(Int(display.height)) display has room for the line")
                continue
            }
            // A hair under the clock's edge is floating point, not overlap.
            let clock = Layout.clockBottom(screenHeight: display.height) - 0.001
            suite.expect(display.maxY - row.maxY >= clock && row.minY - display.minY >= Layout.loginClearance
                         && display.contains(row),
                         "the line keeps the clock's and the login controls' room on \(display)")
        }
        suite.expect(Layout.rowFrame(in: CGRect(x: 0, y: 0, width: 1024, height: 500)) == nil,
                     "a display too short for the line keeps the lock screen as it is")
        suite.expect(Layout.rowFrame(in: CGRect(x: 0, y: 0, width: 64, height: 956)) == nil
                     && Layout.rowFrame(in: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 956)) == nil,
                     "a narrow or unreadable display keeps the lock screen as it is")
        // The fit a person sets moves the island's camera. The locked island
        // is drawn at exactly the fitted camera's height with a resting wing
        // on each side, even when the fit leaves half a point or the width is
        // odd; only its window grows out to whole points, with the extra room clear.
        let fits = [NotchCameraFit(width: 6, height: 3), NotchCameraFit(width: 0, height: 0.5),
                    NotchCameraFit(width: 0, height: -0.5), NotchCameraFit(width: 1, height: 1.5)]
        for fit in fits {
            let fitted = NotchGeometry(screen: measured, safeAreaTop: 32, cameraWidth: 179, cameraFit: fit)
            let camera = fitted.bareCutout
            guard let surface = Layout.islandSurface(in: measured, cameraWidth: camera.width, cameraHeight: camera.height,
                                                     wing: Layout.islandWing) else {
                suite.expect(false, "a notched display has room for the padlock with a fit of \(fit)")
                continue
            }
            let window = Layout.islandFrame(around: surface)
            suite.expect(surface.height == 32 + fit.height && surface.height == camera.height
                         && surface.width == camera.width + Layout.islandWing * 2
                         && surface.maxY == measured.maxY && surface.midX == measured.midX,
                         "with a fit of \(fit) the padlock's island is the fitted camera's height, a wing each side, centred on the camera")
            suite.expect(window == window.integral && window.contains(surface) && window.maxY == surface.maxY
                         && window.width - surface.width < 2 && window.height - surface.height < 1,
                         "with a fit of \(fit) the island's window lands on whole points around it, the island at its top")
        }
        var crowded = NotchGeometry(screen: measured, safeAreaTop: 32, cameraWidth: 179)
        func lockedIsland() -> CGRect? {
            Layout.islandSurface(in: measured, cameraWidth: crowded.bareCutout.width,
                                 cameraHeight: crowded.bareCutout.height, wing: Layout.islandWing)
        }
        let open = lockedIsland()
        crowded.compactSideRoom = 0
        suite.expect(open != nil && lockedIsland() == open,
                     "menus beside the camera while unlocked do not narrow the locked island")
        let wing = Layout.islandWing
        suite.expect(Layout.islandSurface(in: measured, cameraWidth: 0, cameraHeight: 32, wing: wing) == nil
                     && Layout.islandSurface(in: measured, cameraWidth: 179, cameraHeight: .nan, wing: wing) == nil
                     && Layout.islandSurface(in: measured, cameraWidth: 179, cameraHeight: 32, wing: 0) == nil
                     && Layout.islandSurface(in: measured, cameraWidth: 1460, cameraHeight: 32, wing: wing) == nil,
                     "no padlock without a camera to hang it from, or room beside it")
    }

    static func soundContracts(_ suite: TestSuite) {
        let lock = NotchLockScreenSupport.soundURL(locking: true)
        let unlock = NotchLockScreenSupport.soundURL(locking: false)
        suite.expect(lock != nil && unlock != nil && lock != unlock, "locking and unlocking each have their own sound")
        suite.expect([lock, unlock].allSatisfy { $0.map { FileManager.default.fileExists(atPath: $0.path) } == true },
                     "both sounds are files this Mac has")
    }
}
