//
//  AppDelegate.swift
//  JetLedger
//

import OSLog
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by JetLedgerApp after PushNotificationService is created on auth.
    var pushService: PushNotificationService?

    /// Stores receipt_id from a notification tap that arrived before pushService was initialized (cold launch).
    var pendingNotificationReceiptId: UUID?

    // MARK: - Remote Notification Registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        if let pushService {
            Task { await pushService.handleTokenRegistration(token) }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationService.logger.warning("Failed to register for remote notifications: \(error.localizedDescription)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let receiptIdString = userInfo["receipt_id"] as? String,
              let receiptId = UUID(uuidString: receiptIdString) else { return }

        if let pushService {
            pushService.pendingDeepLinkReceiptId = receiptId
        } else {
            // Cold launch — pushService not yet initialized
            pendingNotificationReceiptId = receiptId
        }
    }
}
