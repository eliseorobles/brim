// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct NotchActivityStrings {
    let keepAwakeActivity: String
    let keepAwakeActivityHint: String
}

extension FeatureStrings {
    static func notchActivities(_ language: AppLanguage) -> NotchActivityStrings {
        switch language {
        case .enUS: return NotchActivityStrings(
            keepAwakeActivity: "Show “Keep awake” in the closed island",
            keepAwakeActivityHint: "A running session appears beside the camera with the time it has left, or ∞ when it has no end.")
        }
    }
}
