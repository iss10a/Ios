//
//  GitHubUser.swift
//  GitFolderUploader
//

import Foundation

/// The authenticated account.
struct GitHubUser: Identifiable, Hashable, Codable {
    let id: Int
    let login: String
    let name: String?
    let avatarURL: URL?
    let htmlURL: URL?
    let publicRepos: Int
    let privateRepos: Int

    var displayName: String { name?.isEmpty == false ? name! : login }
}

/// How the current session authenticated.
enum AuthenticationKind: String, Codable {
    case personalAccessToken
    case oauthDeviceFlow

    var titleKey: String {
        switch self {
        case .personalAccessToken: return "auth.kind.pat"
        case .oauthDeviceFlow: return "auth.kind.oauth"
        }
    }
}

/// The intermediate state of an OAuth device-flow login.
struct DeviceCodeSession: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: TimeInterval
    let interval: TimeInterval
    let startedAt: Date

    var expiryDate: Date { startedAt.addingTimeInterval(expiresIn) }
    var isExpired: Bool { Date() >= expiryDate }
}
