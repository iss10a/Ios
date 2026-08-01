//
//  GitHubEndpoints.swift
//  GitFolderUploader
//
//  Every REST route the app uses, in one place.
//

import Foundation

enum GitHubEndpoints {

    // MARK: - Helpers

    /// Percent-encodes a repository path segment while keeping `/` separators.
    static func encodePath(_ path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed
        return path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func base(_ ref: RepoRef) -> String {
        "/repos/\(ref.owner)/\(ref.name)"
    }

    // MARK: - User

    static var currentUser: Endpoint {
        Endpoint(path: "/user")
    }

    static func userRepositories(page: Int, perPage: Int) -> Endpoint {
        Endpoint(path: "/user/repos",
                 query: [
                    "sort": "updated",
                    "direction": "desc",
                    "affiliation": "owner,collaborator,organization_member",
                    "page": String(page),
                    "per_page": String(perPage)
                 ])
    }

    static func createRepository(_ request: NewRepositoryRequest) throws -> Endpoint {
        var payload: [String: Any] = [
            "name": request.name,
            "private": request.isPrivate,
            "auto_init": request.autoInit
        ]
        if !request.description.isEmpty { payload["description"] = request.description }
        if let gitignore = request.gitignoreTemplate, !gitignore.isEmpty {
            payload["gitignore_template"] = gitignore
        }
        if let license = request.licenseTemplate, !license.isEmpty {
            payload["license_template"] = license
        }
        return try Endpoint.json(path: "/user/repos", method: .post, payload: payload)
    }

    static func repository(_ ref: RepoRef) -> Endpoint {
        Endpoint(path: base(ref))
    }

    // MARK: - Search

    static func searchRepositories(query: String, page: Int, perPage: Int) -> Endpoint {
        Endpoint(path: "/search/repositories",
                 query: ["q": query,
                         "page": String(page),
                         "per_page": String(perPage),
                         "sort": "updated"])
    }

    static func searchCode(_ ref: RepoRef, query: String) -> Endpoint {
        Endpoint(path: "/search/code",
                 query: ["q": "\(query) repo:\(ref.fullName)",
                         "per_page": "50"])
    }

    // MARK: - Contents

    static func contents(_ ref: RepoRef, path: String, branch: String) -> Endpoint {
        var endpoint = Endpoint(path: base(ref) + "/contents/" + encodePath(path))
        if !branch.isEmpty { endpoint.query["ref"] = branch }
        return endpoint
    }

    static func putContents(_ ref: RepoRef,
                            path: String,
                            message: String,
                            data: Data,
                            existingSHA: String?,
                            branch: String) throws -> Endpoint {
        var payload: [String: Any] = [
            "message": message,
            "content": Base64.encode(data),
            "branch": branch
        ]
        if let sha = existingSHA { payload["sha"] = sha }
        return try Endpoint.json(path: base(ref) + "/contents/" + encodePath(path),
                                 method: .put,
                                 payload: payload)
    }

    static func deleteContents(_ ref: RepoRef,
                               path: String,
                               message: String,
                               sha: String,
                               branch: String) throws -> Endpoint {
        let payload: [String: Any] = ["message": message, "sha": sha, "branch": branch]
        return try Endpoint.json(path: base(ref) + "/contents/" + encodePath(path),
                                 method: .delete,
                                 payload: payload)
    }

    // MARK: - Git data

    static func branches(_ ref: RepoRef, page: Int, perPage: Int) -> Endpoint {
        Endpoint(path: base(ref) + "/branches",
                 query: ["page": String(page), "per_page": String(perPage)])
    }

    static func reference(_ ref: RepoRef, branch: String) -> Endpoint {
        Endpoint(path: base(ref) + "/git/ref/heads/" + encodePath(branch))
    }

    static func createReference(_ ref: RepoRef, branch: String, sha: String) throws -> Endpoint {
        try Endpoint.json(path: base(ref) + "/git/refs",
                          method: .post,
                          payload: ["ref": "refs/heads/\(branch)", "sha": sha])
    }

    static func updateReference(_ ref: RepoRef, branch: String, sha: String, force: Bool) throws -> Endpoint {
        try Endpoint.json(path: base(ref) + "/git/refs/heads/" + encodePath(branch),
                          method: .patch,
                          payload: ["sha": sha, "force": force])
    }

    static func commit(_ ref: RepoRef, sha: String) -> Endpoint {
        Endpoint(path: base(ref) + "/git/commits/" + sha)
    }

    static func createCommit(_ ref: RepoRef,
                             message: String,
                             treeSHA: String,
                             parents: [String]) throws -> Endpoint {
        try Endpoint.json(path: base(ref) + "/git/commits",
                          method: .post,
                          payload: ["message": message, "tree": treeSHA, "parents": parents])
    }

    static func tree(_ ref: RepoRef, sha: String, recursive: Bool) -> Endpoint {
        var endpoint = Endpoint(path: base(ref) + "/git/trees/" + sha)
        if recursive { endpoint.query["recursive"] = "1" }
        return endpoint
    }

    /// Builds `POST /git/trees`.
    ///
    /// Entries with a `nil` SHA are serialised as an explicit JSON `null`,
    /// which is how the API is told to delete a path from the base tree.
    static func createTree(_ ref: RepoRef, baseTreeSHA: String?, entries: [TreeEntry]) throws -> Endpoint {
        var tree: [[String: Any]] = []
        tree.reserveCapacity(entries.count)
        for entry in entries {
            var node: [String: Any] = [
                "path": entry.path,
                "mode": entry.mode,
                "type": entry.type
            ]
            node["sha"] = entry.sha ?? NSNull()
            tree.append(node)
        }
        var payload: [String: Any] = ["tree": tree]
        if let baseTreeSHA = baseTreeSHA { payload["base_tree"] = baseTreeSHA }
        return try Endpoint.json(path: base(ref) + "/git/trees", method: .post, payload: payload)
    }

    static func createBlob(_ ref: RepoRef, data: Data) throws -> Endpoint {
        try Endpoint.json(path: base(ref) + "/git/blobs",
                          method: .post,
                          payload: ["content": Base64.encode(data), "encoding": "base64"])
    }

    static func blob(_ ref: RepoRef, sha: String) -> Endpoint {
        Endpoint(path: base(ref) + "/git/blobs/" + sha)
    }

    /// Raw blob bytes — avoids the base64 round trip for large files.
    static func rawBlob(_ ref: RepoRef, sha: String) -> Endpoint {
        Endpoint(path: base(ref) + "/git/blobs/" + sha, accept: "application/vnd.github.raw")
    }

    // MARK: - OAuth device flow

    static func deviceCode(clientID: String, scope: String) throws -> Endpoint {
        var endpoint = try Endpoint.json(path: "/login/device/code",
                                         method: .post,
                                         payload: ["client_id": clientID, "scope": scope])
        endpoint.baseURL = GitHubHost.web
        endpoint.accept = "application/json"
        endpoint.requiresAuthentication = false
        return endpoint
    }

    static func deviceToken(clientID: String, deviceCode: String) throws -> Endpoint {
        var endpoint = try Endpoint.json(path: "/login/oauth/access_token",
                                         method: .post,
                                         payload: [
                                            "client_id": clientID,
                                            "device_code": deviceCode,
                                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                                         ])
        endpoint.baseURL = GitHubHost.web
        endpoint.accept = "application/json"
        endpoint.requiresAuthentication = false
        return endpoint
    }
}
