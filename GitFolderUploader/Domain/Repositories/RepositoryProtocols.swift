//
//  RepositoryProtocols.swift
//  GitFolderUploader
//
//  Domain-facing contracts. The Feature layer only ever talks to these, which
//  keeps view models free of any GitHub REST detail and makes them testable.
//

import Foundation

// MARK: - Authentication

protocol AuthRepositoryProtocol: AnyObject {

    /// Token currently stored in the Keychain, if any.
    var storedToken: String? { get }
    var storedKind: AuthenticationKind? { get }
    var oauthClientID: String? { get set }

    /// Validates a Personal Access Token and persists it on success.
    func signIn(withToken token: String) async throws -> GitHubUser

    /// Starts the OAuth device flow and returns the code to show the user.
    func startDeviceFlow(clientID: String, scope: String) async throws -> DeviceCodeSession

    /// Polls once for the device-flow token.
    ///
    /// - Throws: `APIError.deviceFlowPending` while the user has not approved yet.
    func pollDeviceFlow(session: DeviceCodeSession, clientID: String) async throws -> String

    /// Persists a token obtained from the device flow and loads the profile.
    func completeSignIn(token: String, kind: AuthenticationKind) async throws -> GitHubUser

    /// Fetches `/user` with the stored token.
    func currentUser() async throws -> GitHubUser

    func signOut()
}

// MARK: - Repositories

protocol RepositoryServiceProtocol: AnyObject {

    /// Repositories the token can see, newest activity first.
    func listRepositories(page: Int, perPage: Int) async throws -> (items: [Repository], nextPage: Int?)

    /// Global repository search.
    func searchRepositories(query: String, page: Int, perPage: Int) async throws -> (items: [Repository], nextPage: Int?)

    func createRepository(_ request: NewRepositoryRequest) async throws -> Repository

    func repository(_ ref: RepoRef) async throws -> Repository
}

// MARK: - Contents

protocol ContentServiceProtocol: AnyObject {

    func listContents(_ ref: RepoRef, path: String, branch: String) async throws -> [RepositoryItem]

    func fileContent(_ ref: RepoRef, path: String, branch: String) async throws -> FileContent

    /// Creates or replaces a single file (used for folder placeholders, renames…).
    @discardableResult
    func putFile(_ ref: RepoRef,
                 path: String,
                 message: String,
                 data: Data,
                 existingSHA: String?,
                 branch: String) async throws -> String

    func deleteFile(_ ref: RepoRef,
                    path: String,
                    message: String,
                    sha: String,
                    branch: String) async throws
}

// MARK: - Git data (low level)

protocol GitDataServiceProtocol: AnyObject {

    func listBranches(_ ref: RepoRef) async throws -> [Branch]

    func reference(_ ref: RepoRef, branch: String) async throws -> GitReference

    func createBranch(_ ref: RepoRef, name: String, fromSHA: String) async throws -> GitReference

    @discardableResult
    func updateBranch(_ ref: RepoRef, name: String, toSHA: String, force: Bool) async throws -> GitReference

    func commit(_ ref: RepoRef, sha: String) async throws -> GitCommit

    func tree(_ ref: RepoRef, sha: String, recursive: Bool) async throws -> GitTree

    /// Uploads file content and returns the resulting blob SHA.
    ///
    /// - Parameter onProgress: Receives a 0...1 fraction as the body is written,
    ///   which is what drives the per-file progress bar. Pass `nil` when the
    ///   caller does not care.
    func createBlob(_ ref: RepoRef, data: Data, onProgress: ((Double) -> Void)?) async throws -> String

    func createTree(_ ref: RepoRef, baseTreeSHA: String?, entries: [TreeEntry]) async throws -> String

    func createCommit(_ ref: RepoRef,
                      message: String,
                      treeSHA: String,
                      parentSHAs: [String]) async throws -> GitCommit

    /// Raw blob bytes for a SHA (used when downloading folders).
    func blobData(_ ref: RepoRef, sha: String) async throws -> Data
}

// MARK: - Search

protocol SearchServiceProtocol: AnyObject {

    /// File-name search performed against the recursive tree — works on every
    /// repository, including ones the code-search index has not reached.
    func searchFileNames(_ ref: RepoRef, branch: String, query: String) async throws -> [RepositoryItem]

    /// Content search using GitHub's code-search index.
    func searchCode(_ ref: RepoRef, query: String) async throws -> [RepositoryItem]
}

// MARK: - Persistence

protocol UploadJobStoreProtocol: AnyObject {
    func loadAll() -> [UploadJob]
    func save(_ jobs: [UploadJob])
    func save(_ job: UploadJob)
    func delete(id: UUID)
}

extension GitDataServiceProtocol {

    /// Convenience for callers that do not need progress reporting.
    func createBlob(_ ref: RepoRef, data: Data) async throws -> String {
        try await createBlob(ref, data: data, onProgress: nil)
    }
}
