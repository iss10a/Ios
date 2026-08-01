//
//  GitHubDTOs.swift
//  GitFolderUploader
//
//  Wire-format models. They mirror GitHub's JSON exactly and are mapped into
//  the domain entities so no REST detail leaks past the Data layer.
//

import Foundation

// MARK: - User

struct UserDTO: Decodable {
    let id: Int
    let login: String
    let name: String?
    let avatarUrl: URL?
    let htmlUrl: URL?
    let publicRepos: Int?
    let totalPrivateRepos: Int?

    enum CodingKeys: String, CodingKey {
        case id, login, name
        case avatarUrl = "avatar_url"
        case htmlUrl = "html_url"
        case publicRepos = "public_repos"
        case totalPrivateRepos = "total_private_repos"
    }

    func toDomain() -> GitHubUser {
        GitHubUser(id: id,
                   login: login,
                   name: name,
                   avatarURL: avatarUrl,
                   htmlURL: htmlUrl,
                   publicRepos: publicRepos ?? 0,
                   privateRepos: totalPrivateRepos ?? 0)
    }
}

// MARK: - Repository

struct RepositoryDTO: Decodable {

    struct Owner: Decodable {
        let login: String
        let avatarUrl: URL?

        enum CodingKeys: String, CodingKey {
            case login
            case avatarUrl = "avatar_url"
        }
    }

    struct Permissions: Decodable {
        let push: Bool?
        let admin: Bool?
    }

    let id: Int
    let name: String
    let fullName: String
    let owner: Owner
    let isPrivate: Bool
    let fork: Bool?
    let description: String?
    let defaultBranch: String?
    let htmlUrl: URL?
    let updatedAt: Date?
    let size: Int?
    let language: String?
    let stargazersCount: Int?
    let permissions: Permissions?

    enum CodingKeys: String, CodingKey {
        case id, name, owner, fork, description, size, language, permissions
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case htmlUrl = "html_url"
        case updatedAt = "updated_at"
        case stargazersCount = "stargazers_count"
    }

    func toDomain() -> Repository {
        Repository(id: id,
                   name: name,
                   fullName: fullName,
                   ownerLogin: owner.login,
                   ownerAvatarURL: owner.avatarUrl,
                   isPrivate: isPrivate,
                   isFork: fork ?? false,
                   description: description,
                   defaultBranch: defaultBranch ?? "main",
                   htmlURL: htmlUrl,
                   updatedAt: updatedAt,
                   sizeKB: size ?? 0,
                   language: language,
                   stargazersCount: stargazersCount ?? 0,
                   hasPushAccess: permissions?.push ?? true)
    }
}

/// `/search/repositories` envelope.
struct RepositorySearchDTO: Decodable {
    let totalCount: Int
    let incompleteResults: Bool?
    let items: [RepositoryDTO]

    enum CodingKeys: String, CodingKey {
        case items
        case totalCount = "total_count"
        case incompleteResults = "incomplete_results"
    }
}

// MARK: - Branches

struct BranchDTO: Decodable {

    struct Commit: Decodable {
        let sha: String
    }

    let name: String
    let commit: Commit
    let protected: Bool?

    func toDomain() -> Branch {
        Branch(name: name, commitSHA: commit.sha, isProtected: protected ?? false)
    }
}

// MARK: - Contents

struct ContentEntryDTO: Decodable {
    let name: String
    let path: String
    let sha: String
    let size: Int?
    let type: String
    let downloadUrl: URL?
    let content: String?
    let encoding: String?

    enum CodingKeys: String, CodingKey {
        case name, path, sha, size, type, content, encoding
        case downloadUrl = "download_url"
    }

    var kind: RepositoryItem.Kind {
        switch type {
        case "dir": return .directory
        case "symlink": return .symlink
        case "submodule": return .submodule
        default: return .file
        }
    }

    func toDomain() -> RepositoryItem {
        RepositoryItem(name: name,
                       path: path,
                       sha: sha,
                       size: size ?? 0,
                       kind: kind,
                       downloadURL: downloadUrl)
    }

    /// Decodes the inline base64 payload returned for small files.
    func decodedData() -> Data? {
        guard let content = content, encoding == "base64" else { return nil }
        return Base64.decode(content)
    }
}

/// Response of `PUT /contents/{path}`.
struct ContentCommitDTO: Decodable {
    struct Content: Decodable { let sha: String }
    struct Commit: Decodable { let sha: String }
    let content: Content?
    let commit: Commit
}

// MARK: - Git data

struct ReferenceDTO: Decodable {
    struct Object: Decodable {
        let sha: String
        let type: String
    }
    let ref: String
    let object: Object

    func toDomain() -> GitReference {
        GitReference(ref: ref, sha: object.sha)
    }
}

struct CommitDTO: Decodable {

    struct TreePointer: Decodable { let sha: String }
    struct Parent: Decodable { let sha: String }
    struct Author: Decodable {
        let name: String?
        let date: Date?
    }

    let sha: String
    let message: String
    let tree: TreePointer
    let parents: [Parent]?
    let author: Author?
    let htmlUrl: URL?

    enum CodingKeys: String, CodingKey {
        case sha, message, tree, parents, author
        case htmlUrl = "html_url"
    }

    func toDomain() -> GitCommit {
        GitCommit(sha: sha,
                  message: message,
                  treeSHA: tree.sha,
                  parentSHAs: (parents ?? []).map { $0.sha },
                  authorName: author?.name,
                  authorDate: author?.date,
                  htmlURL: htmlUrl)
    }
}

struct TreeEntryDTO: Decodable {
    let path: String
    let mode: String
    let type: String
    let sha: String?
    let size: Int?

    func toDomain() -> TreeEntry {
        TreeEntry(path: path, mode: mode, type: type, sha: sha, size: size)
    }
}

struct TreeDTO: Decodable {
    let sha: String
    let tree: [TreeEntryDTO]
    let truncated: Bool?

    func toDomain() -> GitTree {
        GitTree(sha: sha, entries: tree.map { $0.toDomain() }, isTruncated: truncated ?? false)
    }
}

struct BlobCreationDTO: Decodable {
    let sha: String
}

struct BlobDTO: Decodable {
    let sha: String
    let size: Int?
    let content: String
    let encoding: String

    /// GitHub wraps base64 blob content at 60 characters; strip the newlines.
    func decodedData() -> Data? {
        guard encoding == "base64" else { return Data(content.utf8) }
        return Base64.decode(content)
    }
}

// MARK: - Code search

struct CodeSearchDTO: Decodable {

    struct Item: Decodable {
        let name: String
        let path: String
        let sha: String

        func toDomain() -> RepositoryItem {
            RepositoryItem(name: name, path: path, sha: sha, size: 0, kind: .file, downloadURL: nil)
        }
    }

    let totalCount: Int
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case items
        case totalCount = "total_count"
    }
}

// MARK: - OAuth device flow

struct DeviceCodeDTO: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: TimeInterval
    let interval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }

    func toDomain() -> DeviceCodeSession? {
        guard let url = URL(string: verificationUri) else { return nil }
        return DeviceCodeSession(deviceCode: deviceCode,
                                 userCode: userCode,
                                 verificationURL: url,
                                 expiresIn: expiresIn,
                                 interval: interval,
                                 startedAt: Date())
    }
}

struct DeviceTokenDTO: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?
    let errorDescription: String?
    let interval: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case scope, error, interval
        case accessToken = "access_token"
        case tokenType = "token_type"
        case errorDescription = "error_description"
    }
}

// MARK: - Base64 helper

enum Base64 {

    /// Encodes without line breaks (what the GitHub API expects).
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    /// Decodes tolerantly: GitHub pretty-prints blob payloads with newlines.
    static func decode(_ string: String) -> Data? {
        let cleaned = string
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters])
    }
}
