//
//  GitHubContentService.swift
//  GitFolderUploader
//
//  Contents API. Used for browsing, previewing and single-file writes; bulk
//  folder uploads go through `GitHubGitDataService` instead.
//

import Foundation

final class GitHubContentService: ContentServiceProtocol {

    private let client: HTTPClient
    private let decoder: JSONDecoder

    init(client: HTTPClient) {
        self.client = client
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// `GET /contents/{path}` returns an array for directories and an object for
    /// files, so both shapes are handled here.
    func listContents(_ ref: RepoRef, path: String, branch: String) async throws -> [RepositoryItem] {
        let endpoint = GitHubEndpoints.contents(ref, path: path, branch: branch)
        let raw = try await client.sendRaw(endpoint)

        if let entries = try? decoder.decode([ContentEntryDTO].self, from: raw.value) {
            return entries.map { $0.toDomain() }
        }
        if let single = try? decoder.decode(ContentEntryDTO.self, from: raw.value) {
            return [single.toDomain()]
        }
        throw APIError.decoding("contents")
    }

    func fileContent(_ ref: RepoRef, path: String, branch: String) async throws -> FileContent {
        let endpoint = GitHubEndpoints.contents(ref, path: path, branch: branch)
        let dto: ContentEntryDTO = try await client.send(endpoint)

        if let data = dto.decodedData() {
            return FileContent(path: dto.path, sha: dto.sha, size: dto.size ?? data.count, data: data)
        }
        // Files above 1 MB come back without inline content; fetch the blob.
        if let downloadURL = dto.downloadUrl {
            let data = try await client.download(from: downloadURL)
            return FileContent(path: dto.path, sha: dto.sha, size: data.count, data: data)
        }
        let blob: BlobDTO = try await client.send(GitHubEndpoints.blob(ref, sha: dto.sha))
        guard let data = blob.decodedData() else { throw APIError.decoding("blob") }
        return FileContent(path: dto.path, sha: dto.sha, size: data.count, data: data)
    }

    @discardableResult
    func putFile(_ ref: RepoRef,
                 path: String,
                 message: String,
                 data: Data,
                 existingSHA: String?,
                 branch: String) async throws -> String {
        let endpoint = try GitHubEndpoints.putContents(ref,
                                                       path: path,
                                                       message: message,
                                                       data: data,
                                                       existingSHA: existingSHA,
                                                       branch: branch)
        let dto: ContentCommitDTO = try await client.send(endpoint)
        return dto.commit.sha
    }

    func deleteFile(_ ref: RepoRef,
                    path: String,
                    message: String,
                    sha: String,
                    branch: String) async throws {
        let endpoint = try GitHubEndpoints.deleteContents(ref,
                                                          path: path,
                                                          message: message,
                                                          sha: sha,
                                                          branch: branch)
        try await client.sendIgnoringBody(endpoint)
    }
}
