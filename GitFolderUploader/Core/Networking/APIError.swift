//
//  APIError.swift
//  GitFolderUploader
//

import Foundation

/// Every failure surfaced by the networking and data layers.
enum APIError: LocalizedError, Equatable {

    case invalidURL(String)
    case invalidResponse
    case unauthorized
    case forbidden(String)
    case notFound
    case conflict(String)
    case validationFailed(String)
    case rateLimited(retryAfter: TimeInterval)
    case server(status: Int, message: String)
    case decoding(String)
    case transport(String)
    case cancelled
    case fileTooLarge(path: String, bytes: Int)
    case missingToken
    case deviceFlowPending
    case deviceFlowSlowDown(TimeInterval)
    case deviceFlowExpired
    case deviceFlowDenied
    case folderAccessDenied

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return L10n.t("error.invalid_url") + ": " + value
        case .invalidResponse:
            return L10n.t("error.invalid_response")
        case .unauthorized:
            return L10n.t("error.unauthorized")
        case .forbidden(let message):
            return message.isEmpty ? L10n.t("error.forbidden") : message
        case .notFound:
            return L10n.t("error.not_found")
        case .conflict(let message):
            return message.isEmpty ? L10n.t("error.conflict") : message
        case .validationFailed(let message):
            return message.isEmpty ? L10n.t("error.validation") : message
        case .rateLimited(let retryAfter):
            return L10n.t("error.rate_limited") + " (\(Int(retryAfter))s)"
        case .server(let status, let message):
            return "HTTP \(status): \(message)"
        case .decoding(let detail):
            return L10n.t("error.decoding") + ": " + detail
        case .transport(let detail):
            return L10n.t("error.network") + ": " + detail
        case .cancelled:
            return L10n.t("error.cancelled")
        case .fileTooLarge(let path, let bytes):
            return L10n.t("error.file_too_large") + " " + path + " (\(bytes))"
        case .missingToken:
            return L10n.t("error.missing_token")
        case .deviceFlowPending:
            return L10n.t("auth.device.pending")
        case .deviceFlowSlowDown:
            return L10n.t("auth.device.slow_down")
        case .deviceFlowExpired:
            return L10n.t("auth.device.expired")
        case .deviceFlowDenied:
            return L10n.t("auth.device.denied")
        case .folderAccessDenied:
            return L10n.t("error.folder_access")
        }
    }

    /// Transient failures are automatically retried by `HTTPClient`.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport:
            return true
        case .server(let status, _):
            return status >= 500
        default:
            return false
        }
    }
}
