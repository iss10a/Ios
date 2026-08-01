//
//  Repository.swift
//  GitFolderUploader
//

import Foundation

/// Minimal owner/name pair used as the identity of a repository across layers.
struct RepoRef: Hashable, Codable, Identifiable {
    let owner: String
    let name: String

    var id: String { fullName }
    var fullName: String { "\(owner)/\(name)" }

    init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parses an `owner/name` string.
    init?(fullName: String) {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.owner = parts[0]
        self.name = parts[1]
    }
}

/// A GitHub repository as shown in the list and browser screens.
struct Repository: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let fullName: String
    let ownerLogin: String
    let ownerAvatarURL: URL?
    let isPrivate: Bool
    let isFork: Bool
    let description: String?
    let defaultBranch: String
    let htmlURL: URL?
    let updatedAt: Date?
    let sizeKB: Int
    let language: String?
    let stargazersCount: Int
    /// `false` when the token only has read access.
    let hasPushAccess: Bool

    var ref: RepoRef { RepoRef(owner: ownerLogin, name: name) }
}

/// Payload for repository creation.
struct NewRepositoryRequest {
    var name: String
    var description: String
    var isPrivate: Bool
    /// Creating with a README gives the repo an initial commit, which the Git
    /// Data API requires before trees can be pushed.
    var autoInit: Bool
    var gitignoreTemplate: String?
    var licenseTemplate: String?

    init(name: String,
         description: String = "",
         isPrivate: Bool = true,
         autoInit: Bool = true,
         gitignoreTemplate: String? = nil,
         licenseTemplate: String? = nil) {
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
        self.autoInit = autoInit
        self.gitignoreTemplate = gitignoreTemplate
        self.licenseTemplate = licenseTemplate
    }
}
