//
//  OfflineIdentity.swift
//  JetLedger
//

import Foundation

struct OfflineIdentity: Codable {
    let userId: UUID
    let email: String
    let accountId: UUID
    let accountName: String
    let role: String

    var accountRole: AccountRole? {
        AccountRole(rawValue: role)
    }

    // MARK: - Persistence

    private static let key = "offlineIdentity"

    static func save(_ identity: OfflineIdentity) {
        if let data = try? JSONEncoder().encode(identity) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> OfflineIdentity? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OfflineIdentity.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
