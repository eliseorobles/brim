// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import os.log
import UserNotifications

enum Notifier {
    static let whatsAppOrganizerUndoActionIdentifier =
        "com.roblesconsulting.brim.notification.whatsapp-organizer.undo"
    private static let whatsAppOrganizerTransactionKey =
        "com.roblesconsulting.brim.notification.whatsapp-organizer.transaction"
    private static let whatsAppOrganizerCategoryIdentifier =
        "com.roblesconsulting.brim.notification.whatsapp-organizer"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brim",
                                    category: "notifications")

    /// Asks the system to allow Brim's alerts (it prompts only once ever);
    /// its answer is read into Permissions, so every warning row shows it.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            // A denied prompt is the user's call; a request that ERRORS means
            // notifications silently cannot work at all — leave a trace so
            // that state is diagnosable instead of invisible.
            if let error {
                log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                log.notice("notification authorization not granted")
            }
            Permissions.shared.refreshNotifications()
        }
    }

    /// `delivered` says what became of it (on the notification center's
    /// queue): a caller that must not lose an alert records a drop.
    static func post(title: String, body: String, delivered: ((NotificationDelivery) -> Void)? = nil) {
        post(title: title, body: body, categoryIdentifier: nil, userInfo: [:], delivered: delivered)
    }

    static func postWhatsAppOrganization(title: String,
                                         body: String,
                                         undoTitle: String,
                                         transactionID: UUID) {
        let undo = UNNotificationAction(
            identifier: whatsAppOrganizerUndoActionIdentifier,
            title: undoTitle,
            options: [.foreground])
        post(title: title, body: body,
             category: UNNotificationCategory(identifier: whatsAppOrganizerCategoryIdentifier,
                                              actions: [undo], intentIdentifiers: [], options: []),
             userInfo: [whatsAppOrganizerTransactionKey: transactionID.uuidString])
    }

    /// A notification with buttons. Its category joins the ones other
    /// features registered instead of replacing them (setting categories
    /// replaces the whole set), so one feature's buttons never take
    /// another's off a notification still on screen.
    static func post(title: String,
                     body: String,
                     category: UNNotificationCategory,
                     userInfo: [AnyHashable: Any] = [:],
                     delivered: ((NotificationDelivery) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != category.identifier }
            categories.insert(category)
            center.setNotificationCategories(categories)
            post(title: title, body: body, categoryIdentifier: category.identifier, userInfo: userInfo,
                 delivered: delivered)
        }
    }

    static func whatsAppOrganizerTransactionID(from response: UNNotificationResponse) -> UUID? {
        guard response.actionIdentifier == whatsAppOrganizerUndoActionIdentifier,
              let raw = response.notification.request.content.userInfo[
                whatsAppOrganizerTransactionKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    private static func post(title: String,
                             body: String,
                             categoryIdentifier: String?,
                             userInfo: [AnyHashable: Any],
                             delivered: ((NotificationDelivery) -> Void)?) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let permission = NotificationPermissionState(settings.authorizationStatus)
            guard permission.delivers else {
                log.notice("notification dropped: authorization status \(settings.authorizationStatus.rawValue)")
                delivered?(.dropped(permission))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    log.error("notification delivery failed: \(error.localizedDescription, privacy: .public)")
                    delivered?(.failed(error.localizedDescription))
                } else {
                    delivered?(.delivered)
                }
            }
        }
    }
}
