//
//  Constants.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation

enum AppConstants {
    enum Supabase {
        static let url: URL = {
            guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
                  !urlString.isEmpty,
                  let url = URL(string: urlString)
            else {
                fatalError("Missing SUPABASE_URL — copy Secrets.xcconfig.example to Secrets.xcconfig and fill in your values")
            }
            return url
        }()

        static let anonKey: String = {
            guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
                  !key.isEmpty,
                  key != "your-anon-key"
            else {
                fatalError("Missing SUPABASE_ANON_KEY — copy Secrets.xcconfig.example to Secrets.xcconfig and fill in your values")
            }
            return key
        }()
    }

    enum Image {
        static let maxFileSize = 10 * 1024 * 1024  // 10MB
        static let maxDimension: CGFloat = 4096
        static let jpegCompression: CGFloat = 0.8
    }

    enum WebAPI {
        static let baseURL: URL = {
            guard let urlString = Bundle.main.object(forInfoDictionaryKey: "JetLedgerAPIURL") as? String,
                  !urlString.isEmpty,
                  let url = URL(string: urlString)
            else {
                fatalError("Missing JETLEDGER_API_URL — add it to Secrets.xcconfig")
            }
            return url
        }()

        static let receiptUploadURL = "/api/receipts/upload-url"
        static let receiptDownloadURL = "/api/receipts/download-url"
        static let receipts = "/api/receipts"
        static let receiptStatus = "/api/receipts/status"
        static let deviceTokens = "/api/user/device-tokens"
    }

    enum Sync {
        static let statusCheckBatchSize = 50
        static let networkQueryTimeoutSeconds: UInt64 = 15
        static let remoteFetchLimit = 200
    }

    enum Cleanup {
        static let defaultImageRetentionDays = 7
        static let metadataRetentionMultiplier = 2
        static let imageRetentionKey = "imageRetentionDays"
    }

    enum PDF {
        static let maxFileSize = 20 * 1024 * 1024  // 20MB
    }

    enum Links {
        static let webApp = URL(string: "https://jetledger.io")!
        static let support = URL(string: "mailto:support@jetledger.io")!
    }

    enum SharedContainer {
        static let appGroupIdentifier = "group.io.jetledger.JetLedger"
        static let pendingImportsDirectory = "shared-imports"
    }
}

// MARK: - Timeout Utility

struct TimeoutError: LocalizedError {
    let seconds: UInt64
    var errorDescription: String? { "Operation timed out after \(seconds) seconds" }
}

/// Runs an async operation with a timeout. If the operation doesn't complete
/// within the specified duration, throws `TimeoutError`.
func withTimeout<T: Sendable>(
    seconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw TimeoutError(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw TimeoutError(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}

// MARK: - Bundle Version

extension Bundle {
    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(version) (Build \(build))"
    }
}

// MARK: - String Sanitization

extension String {
    /// Strips HTML tags to prevent XSS when content is rendered in the web app.
    var strippingHTMLTags: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
