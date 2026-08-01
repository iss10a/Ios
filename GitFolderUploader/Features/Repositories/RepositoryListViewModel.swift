//
//  RepositoryListViewModel.swift
//  GitFolderUploader
//

import Foundation
import SwiftUI

@MainActor
final class RepositoryListViewModel: ObservableObject {

    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var filterText: String = ""

    private var nextPage: Int? = 1
    private let environment: AppEnvironment

    init(environment: AppEnvironment? = nil) {
        self.environment = environment ?? .shared
    }

    /// Local filter over the already-loaded page set. Global search lives in
    /// its own tab and hits `/search/repositories`.
    var visibleRepositories: [Repository] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return repositories }
        return repositories.filter {
            $0.name.lowercased().contains(needle)
                || $0.fullName.lowercased().contains(needle)
                || ($0.description ?? "").lowercased().contains(needle)
        }
    }

    // MARK: - Loading

    func loadFirstPageIfNeeded() async {
        guard repositories.isEmpty, !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        nextPage = 1
        defer { isLoading = false }

        do {
            let result = try await environment.listRepositories(page: 1)
            repositories = result.items
            nextPage = result.nextPage
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Called when the last row appears — infinite scrolling.
    func loadMoreIfNeeded(currentItem: Repository) async {
        guard let page = nextPage, !isLoadingMore, !isLoading else { return }
        guard repositories.last?.id == currentItem.id else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let result = try await environment.listRepositories(page: page)
            let existing = Set(repositories.map { $0.id })
            repositories.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            nextPage = result.nextPage
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Inserts a freshly created repository at the top without a full reload.
    func insert(_ repository: Repository) {
        repositories.removeAll { $0.id == repository.id }
        repositories.insert(repository, at: 0)
    }
}
