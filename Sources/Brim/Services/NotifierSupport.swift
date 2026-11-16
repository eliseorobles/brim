// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import UserNotifications

/// Brim's notification permission as the system reports it, and what each
/// state means for an alert. Permissions publishes it; Notifier decides with
/// it whether a notification can be shown at all.
///
/// T-52: Brim's notifications were denied (UNAuthorizationStatus 1), so every
/// memory alert of a night was dropped with nothing but a log line. A check
/// on launch and whenever the Memory panel or its Settings page opens asks
/// the system once when it was never asked, and shows a warning when the
/// person wants alerts and the system has them off.
enum NotificationPermissionState: Equatable {
    case granted, denied, undetermined, unknown

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional: self = .granted
        case .denied: self = .denied
        case .notDetermined: self = .undetermined
        @unknown default: self = .unknown
        }
    }

    /// The system shows Brim's alerts.
    var delivers: Bool { self == .granted }

    /// A check asks the system for permission: only when it was never asked
    /// and the person wants alerts. A denial is the person's call, made in
    /// System Settings; Brim never asks again over it.
    func asksOnCheck(wantsAlerts: Bool) -> Bool { wantsAlerts && self == .undetermined }

    /// The warning row ("Brim can't alert you"): alerts wanted, and the
    /// system has them off.
    func showsWarning(wantsAlerts: Bool) -> Bool { wantsAlerts && self == .denied }

    /// System Settings' Notifications pane, on Brim's own entry when the
    /// bundle id is known.
    static func settingsURL(bundleID: String?) -> URL? {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let bundleID, !bundleID.isEmpty,
              let id = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return URL(string: pane) }
        return URL(string: pane + "?id=" + id)
    }
}

/// What became of one notification Brim asked to post.
enum NotificationDelivery: Equatable {
    case delivered
    /// Not shown: the system does not allow Brim's alerts (off, or never asked).
    case dropped(NotificationPermissionState)
    case failed(String)
}
