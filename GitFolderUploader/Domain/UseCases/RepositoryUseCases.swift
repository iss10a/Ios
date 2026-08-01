//
//  RepositoryUseCases.swift
//  GitFolderUploader
//

import Foundation

/// Paged list of the signed-in user's repositories.
struct ListRepositoriesUseCase {
    let service: RepositoryServiceProtocol

    func callAsFunction(page: Int, perPage: Int = 30) async throws -> (items: [Repository], nextPage: Int?) {
        try await service.listRepositories(page: page, perPage: perPage)
    }
}

/// Repository search across GitHub, scoped to the user when the query is bare.
struct SearchRepositoriesUseCase {
    let service: RepositoryServiceProtocol

    func callAsFunction(query: String,
                        page: Int,
                        perPage: Int = 30) async throws -> (items: [Repository], nextPage: Int?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], nil) }
        return try await service.searchRepositories(query: trimmed, page: page, perPage: perPage)
    }
}

/// Creates a repository, validating the name locally first.
struct CreateRepositoryUseCase {
    let service: RepositoryServiceProtocol

    /// GitHub accepts letters, digits, `.`, `-` and `_`.
    static func validate(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L10n.t("create.error.empty") }
        if trimmed.count > 100 { return L10n.t("create.error.long") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil { return L10n.t("create.error.chars") }
        return nil
    }

    func callAsFunction(_ request: NewRepositoryRequest) async throws -> Repository {
        if let problem = Self.validate(name: request.name) {
            throw APIError.validationFailed(problem)
        }
        var normalized = request
        normalized.name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await service.createRepository(normalized)
    }
}
