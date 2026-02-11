//
//  Constants.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation

enum AppConstants {
    static let supabaseURL = URL(string: "https://your-project.supabase.co")!
    static let supabaseAnonKey = "your-anon-key"
    
    // These should come from a .xcconfig or environment in production
    // For now, hardcoded for development
    
    static let maxImageSize = 10 * 1024 * 1024  // 10MB
    static let maxImageDimension: CGFloat = 4096
    static let jpegCompression: CGFloat = 0.8
}
