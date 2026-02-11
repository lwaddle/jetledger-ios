//
//  Constants.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation
import SwiftUI

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

    enum API {
        static let receiptUploadURL = "/api/receipts/upload-url"
        static let receipts = "/api/receipts"
        static let receiptStatus = "/api/receipts/status"
    }

    enum Colors {
        static let primaryAccent = Color(red: 30 / 255, green: 58 / 255, blue: 95 / 255)
    }
}
