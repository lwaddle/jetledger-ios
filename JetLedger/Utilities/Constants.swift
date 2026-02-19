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
        static let receipts = "/api/receipts"
        static let receiptStatus = "/api/receipts/status"
    }

    enum Sync {
        static let maxConcurrentUploads = 2
        static let statusCheckBatchSize = 50
    }

    enum Cleanup {
        static let defaultImageRetentionDays = 7
        static let metadataRetentionMultiplier = 2
        static let imageRetentionKey = "imageRetentionDays"
    }

    enum PDF {
        static let maxFileSize = 20 * 1024 * 1024  // 20MB
    }

    enum SharedContainer {
        static let appGroupIdentifier = "group.io.jetledger.JetLedger"
        static let pendingImportsDirectory = "shared-imports"
    }
}
