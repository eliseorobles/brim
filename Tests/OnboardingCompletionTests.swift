// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit

/// Run the production window-close callback and onboarding completion write
/// with isolated preferences. No app windows become visible.
enum OnboardingCompletionTests {
    enum UserDefaults { static var standard: Foundation.UserDefaults! }
    enum WindowActivationPolicy {
        static var releases = 0
        static func release() { releases += 1 }
    }
    final class SettingsWindowVisibility {
        static let shared = SettingsWindowVisibility()
        func set(_ visible: Bool) {}
    }
    class Fixture {
        var settingsWindow: NSWindow?
        var settingsKeepsAppRegular = false
        var onboardingWindow: NSWindow?
        var isTerminating = false
        func saveSettingsWindowSize(_ window: NSWindow) {}
    }

    static func run(_ suite: TestSuite) {
        let domain = "brim.tests.onboarding-completion.\(UUID().uuidString)"
        UserDefaults.standard = Foundation.UserDefaults(suiteName: domain)!
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard = nil
        }
        func close(_ window: NSWindow?, in host: Host) {
            guard let window else { suite.expect(false, "the window to close exists"); return }
            host.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        }

        let finished = Host()
        finished.onboardingWindow = NSWindow()
        close(finished.onboardingWindow, in: finished)
        suite.expect(finished.onboardingWindow == nil
                     && UserDefaults.standard.bool(forKey: DefaultsKey.hasOnboarded)
                     && UserDefaults.standard.integer(forKey: DefaultsKey.featuresOnboardingVersion)
                        == OnboardingInfo.currentFeatureSet,
                     "closing the finished onboarding marks the first run and its feature set as seen")

        UserDefaults.standard.removePersistentDomain(forName: domain)
        let relaunching = Host()
        relaunching.onboardingWindow = NSWindow()
        relaunching.isTerminating = true
        close(relaunching.onboardingWindow, in: relaunching)
        suite.expect(relaunching.onboardingWindow == nil
                     && !UserDefaults.standard.bool(forKey: DefaultsKey.hasOnboarded),
                     "a relaunch while granting access leaves onboarding to resume at the same step")

        let settings = Host()
        settings.settingsWindow = NSWindow()
        settings.settingsKeepsAppRegular = true
        let releases = WindowActivationPolicy.releases
        close(settings.settingsWindow, in: settings)
        suite.expect(!settings.settingsKeepsAppRegular && WindowActivationPolicy.releases == releases + 1
                     && !UserDefaults.standard.bool(forKey: DefaultsKey.hasOnboarded),
                     "closing Settings hands back its activation and leaves onboarding alone")
    }
}
