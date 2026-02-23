//
//  PushNotificationService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

@Observable
class PushNotificationService {
    static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "PushNotificationService")

    var pendingDeepLinkReceiptId: UUID?

    private let receiptAPI: ReceiptAPIService
    private var registeredToken: String?

    init(receiptAPI: ReceiptAPIService) {
        self.receiptAPI = receiptAPI
    }

    // MARK: - Permission & Registration

    func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    Self.logger.info("Push notification permission granted")
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    Self.logger.info("Push notification permission denied by user")
                }
            } catch {
                Self.logger.error("Failed to request notification permission: \(error.localizedDescription)")
            }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            Self.logger.info("Push notifications denied — skipping registration")
        @unknown default:
            break
        }
    }

    // MARK: - Token Management

    func handleTokenRegistration(_ token: String) async {
        guard token != registeredToken else { return }
        do {
            try await receiptAPI.registerDeviceToken(token)
            registeredToken = token
            Self.logger.info("Device token registered with server")
        } catch {
            Self.logger.error("Failed to register device token: \(error.localizedDescription)")
        }
    }

    func unregisterToken() async {
        guard let token = registeredToken else { return }
        do {
            try await receiptAPI.unregisterDeviceToken(token)
            Self.logger.info("Device token unregistered from server")
        } catch {
            Self.logger.error("Failed to unregister device token: \(error.localizedDescription)")
        }
        registeredToken = nil
    }
}
