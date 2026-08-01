//
//  SearchUseCases.swift
//  GitFolderUploader
//

import Foundation

/// Searches file names inside one repository.
struct SearchFilesUseCase {
    let service: SearchServiceProtocol

    func callAsFunction(_ ref: RepoRef, branch: String, query: String) async throws -> [RepositoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }
        return try await service.searchFileNames(ref, branch: branch, query: trimmed)
    }
}

/// Searches file *contents* using GitHub's code index.
struct SearchCodeUseCase {
    let service: SearchServiceProtocol

    func callAsFunction(_ ref: RepoRef, query: String) async throws -> [RepositoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
        return try await service.searchCode(ref, query: trimmed)
    }
}
