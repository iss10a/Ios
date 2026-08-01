//
//  RepositorySearchView.swift
//  GitFolderUploader
//
//  Global repository search backed by `/search/repositories`.
//

import SwiftUI

@MainActor
final class RepositorySearchViewModel: ObservableObject {

    @Published var query: String = ""
    @Published private(set) var results: [Repository] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published private(set) var hasSearched = false

    private var nextPage: Int?
    private var searchTask: Task<Void, Never>?
    private let environment: AppEnvironment

    init(environment: AppEnvironment? = nil) {
        self.environment = environment ?? .shared
    }

    /// Cancels in-flight work. Called from `onDisappear`; `deinit` cannot touch
    /// isolated state on a main-actor class.
    func cancelPendingWork() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// Debounced search so a request is not fired on every keystroke.
    func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            hasSearched = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    func search() async {
        isSearching = true
        errorMessage = nil
        defer {
            isSearching = false
            hasSearched = true
        }
        do {
            let result = try await environment.searchRepositories(query: query, page: 1)
            results = result.items
            nextPage = result.nextPage
        } catch is CancellationError {
            return
        } catch {
            errorMessage = FileBrowserViewModel.describe(error)
        }
    }

    func loadMoreIfNeeded(currentItem: Repository) async {
        guard let page = nextPage, !isLoadingMore, !isSearching else { return }
        guard results.last?.id == currentItem.id else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await environment.searchRepositories(query: query, page: page)
            let existing = Set(results.map { $0.id })
            results.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            nextPage = result.nextPage
        } catch {
            errorMessage = FileBrowserViewModel.describe(error)
        }
    }
}

struct RepositorySearchView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @StateObject private var viewModel = RepositorySearchViewModel()

    var body: some View {
        List {
            if let message = viewModel.errorMessage {
                Section {
                    ErrorBanner(message: message) { Task { await viewModel.search() } }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(viewModel.results) { repository in
                NavigationLink {
                    FileBrowserView(repository: repository)
                } label: {
                    RepositoryRow(repository: repository)
                }
                .task { await viewModel.loadMoreIfNeeded(currentItem: repository) }
            }

            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(L10n.t("search.title"))
        .searchable(text: $viewModel.query, prompt: L10n.t("search.prompt"))
        .onChange(of: viewModel.query) { _ in viewModel.scheduleSearch() }
        .onSubmit(of: .search) { Task { await viewModel.search() } }
        .onDisappear { viewModel.cancelPendingWork() }
        .overlay {
            if viewModel.isSearching && viewModel.results.isEmpty {
                LoadingView(title: L10n.t("search.searching"))
            } else if viewModel.results.isEmpty {
                EmptyStateView(symbol: "magnifyingglass",
                               title: viewModel.hasSearched
                                    ? L10n.t("search.none.title")
                                    : L10n.t("search.start.title"),
                               message: viewModel.hasSearched
                                    ? L10n.t("search.none.message")
                                    : L10n.t("search.start.message"))
            }
        }
    }
}
