//
//  R2UploadService.swift
//  JetLedger
//

import Foundation

class R2UploadService {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    func upload(data: Data, to presignedURL: String, contentType: String) async throws {
        guard let url = URL(string: presignedURL) else {
            throw R2UploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let (_, response) = try await Self.session.upload(for: request, from: data)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw R2UploadError.uploadFailed(statusCode: code)
        }
    }
}

enum R2UploadError: Error, LocalizedError {
    case invalidURL
    case uploadFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid upload URL."
        case .uploadFailed(let code): "Upload failed with status \(code)."
        }
    }
}
