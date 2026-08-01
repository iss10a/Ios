//
//  GitHubGitDataService.swift
//  GitFolderUploader
//
//  Low level Git Data API. Everything that has to scale — folder uploads,
//  recursive downloads, atomic renames — is built on these calls.
//

import Foundation

final class GitHubGitDataService: GitDataServiceProtocol {

    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - Branches & refs

    func listBranches(_ ref: RepoRef) async throws -> [Branch] {
        let endpoint = GitHubEndpoints.branches(ref, page: 1, perPage: 100)
        let dtos: [BranchDTO] = try await client.sendAllPages(endpoint, perPage: 100)
        return dtos.map { $0.toDomain() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func reference(_ ref: RepoRef, branch: String) async throws -> GitReference {
        let dto: ReferenceDTO = try await client.send(GitHubEndpoints.reference(ref, branch: branch))
        return dto.toDomain()
    }

    func createBranch(_ ref: RepoRef, name: String, fromSHA: String) async throws -> GitReference {
        let endpoint = try GitHubEndpoints.createReference(ref, branch: name, sha: fromSHA)
        let dto: ReferenceDTO = try await client.send(endpoint)
        return dto.toDomain()
    }

    @discardableResult
    func updateBranch(_ ref: RepoRef, name: String, toSHA: String, force: Bool) async throws -> GitReference {
        let endpoint = try GitHubEndpoints.updateReference(ref, branch: name, sha: toSHA, force: force)
        let dto: ReferenceDTO = try await client.send(endpoint)
        return dto.toDomain()
    }

    // MARK: - Commits & trees

    func commit(_ ref: RepoRef, sha: String) async throws -> GitCommit {
        let dto: CommitDTO = try await client.send(GitHubEndpoints.commit(ref, sha: sha))
        return dto.toDomain()
    }

    func tree(_ ref: RepoRef, sha: String, recursive: Bool) async throws -> GitTree {
        let dto: TreeDTO = try await client.send(GitHubEndpoints.tree(ref, sha: sha, recursive: recursive))
        return dto.toDomain()
    }

    func createTree(_ ref: RepoRef, baseTreeSHA: String?, entries: [TreeEntry]) async throws -> String {
        let endpoint = try GitHubEndpoints.createTree(ref, baseTreeSHA: baseTreeSHA, entries: entries)
        let dto: TreeDTO = try await client.send(endpoint)
        return dto.sha
    }

    func createCommit(_ ref: RepoRef,
                      message: String,
                      treeSHA: String,
                      parentSHAs: [String]) async throws -> GitCommit {
        let endpoint = try GitHubEndpoints.createCommit(ref,
                                                        message: message,
                                                        treeSHA: treeSHA,
                                                        parents: parentSHAs)
        let dto: CommitDTO = try await client.send(endpoint)
        return dto.toDomain()
    }

    // MARK: - Blobs

    func createBlob(_ ref: RepoRef, data: Data, onProgress: ((Double) -> Void)?) async throws -> String {
        guard data.count <= FileSystemScanner.maxBlobBytes else {
            throw APIError.fileTooLarge(path: ref.fullName, bytes: data.count)
        }
        let endpoint = try GitHubEndpoints.createBlob(ref, data: data)
        let dto: BlobCreationDTO = try await client.sendUploading(endpoint, onProgress: onProgress)
        return dto.sha
    }

    /// Fetches blob bytes using the `raw` media type, avoiding a base64 hop.
    func blobData(_ ref: RepoRef, sha: String) async throws -> Data {
        do {
            let raw = try await client.sendRaw(GitHubEndpoints.rawBlob(ref, sha: sha))
            return raw.value
        } catch {
            // Some proxies do not honour the raw media type; fall back to JSON.
            let dto: BlobDTO = try await client.send(GitHubEndpoints.blob(ref, sha: sha))
            guard let data = dto.decodedData() else { throw APIError.decoding("blob") }
            return data
        }
    }
}
