// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// Who Brim is, read from the running bundle, and the credit it owes upstream.
///
/// build.sh sets the bundle IDs: `com.roblesconsulting.brim` for the release
/// build and the same ID plus `.dev` for the Developer build. Upstream code that
/// asks "is this identifier ours?" calls in here instead of naming an ID, so the
/// answer follows the build and never matches Vorssaint's own apps or files.
enum BrimIdentity {
    /// Shown on the About surfaces. Brim is a modified Vorssaint, and the GPL
    /// asks that its origin and license stay visible.
    static let upstreamCredit = "Based on Vorssaint, GPL-3.0-or-later"

    /// The Developer build's ID is the release ID plus this suffix, the same
    /// rule `AppInfo.isDeveloperBuild` reads.
    static let developerSuffix = ".dev"

    /// The running app's bundle ID. nil in a bare binary such as the test runner
    /// or `--selftest`, where nothing counts as ours. Tests assign it to stand in
    /// for an installed bundle; the app never writes it.
    static var bundleIdentifier: String? = Bundle.main.bundleIdentifier

    /// The release build's ID, whichever build is running.
    static var releaseBundleIdentifier: String? {
        guard let id = bundleIdentifier else { return nil }
        let release = id.hasSuffix(developerSuffix) ? String(id.dropLast(developerSuffix.count)) : id
        return release.isEmpty ? nil : release
    }

    /// Whether `identifier` is either build or something they own: the
    /// `.fan-control` helper, or a team-prefixed or `group.`
    /// container. Case is ignored. A domain ends at a dot, so an unrelated ID that
    /// only starts with the same letters is not ours.
    static func owns(_ identifier: String?) -> Bool {
        guard let identifier, let release = releaseBundleIdentifier?.lowercased() else { return false }
        return ("." + identifier.lowercased() + ".").contains("." + release + ".")
    }
}
