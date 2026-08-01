//
//  GitHubRepositoryService.swift
//  GitFolderUploader
//

import Foundation

final class GitHubRepositoryService: RepositoryServiceProtocol {

    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    func listRepositories(page: Int, perPage: Int) async throws -> (items: [Repository], nextPage: Int?) {
        let endpoint = GitHubEndpoints.userRepositories(page: page, perPage: perPage)
        let response: APIResponse<[RepositoryDTO]> = try await client.sendWithMetadata(endpoint)
        return (response.value.map { $0.toDomain() }, response.nextPage)
    }

    func searchRepositories(query: String, page: Int, perPage: Int) async throws -> (items: [Repository], nextPage: Int?) {
        let endpoint = GitHubEndpoints.searchRepositories(query: query, page: page, perPage: perPage)
        let response: APIResponse<RepositorySearchDTO> = try await client.sendWithMetadata(endpoint)
        let items = response.value.items.map { $0.toDomain() }
        // The search API caps results at 1000; stop paging once exhausted.
        let hasMore = page * perPage < min(response.value.totalCount, 1000) && !items.isEmpty
        return (items, hasMore ? page + 1 : nil)
    }

    func createRepository(_ request: NewRepositoryRequest) async throws -> Repository {
        let endpoint = try GitHubEndpoints.createRepository(request)
        let dto: RepositoryDTO = try await client.send(endpoint)
        return dto.toDomain()
    }

    func repository(_ ref: RepoRef) async throws -> Repository {
        let dto: RepositoryDTO = try await client.send(GitHubEndpoints.repository(ref))
        return dto.toDomain()
    }
}
