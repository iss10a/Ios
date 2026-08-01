//
//  RepositoryListView.swift
//  GitFolderUploader
//
//  Lists the signed-in user's repositories with pull-to-refresh, infinite
//  scrolling and a shortcut to create a new one.
//

import SwiftUI

struct RepositoryListView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @StateObject private var viewModel = RepositoryListViewModel()
    @State private var isCreating = false

    var body: some View {
        List {
            if let message = viewModel.errorMessage {
                Section {
                    ErrorBanner(message: message) {
                        Task { await viewModel.refresh() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(viewModel.visibleRepositories) { repository in
                NavigationLink(value: repository) {
                    RepositoryRow(repository: repository)
                }
                .task {
                    await viewModel.loadMoreIfNeeded(currentItem: repository)
                }
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
        .navigationTitle(L10n.t("repos.title"))
        .navigationDestination(for: Repository.self) { repository in
            FileBrowserView(repository: repository)
        }
        .searchable(text: $viewModel.filterText, prompt: L10n.t("repos.filter"))
        .refreshable { await viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Label(L10n.t("repos.create"), systemImage: "plus")
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.repositories.isEmpty {
                LoadingView()
            } else if !viewModel.isLoading && viewModel.visibleRepositories.isEmpty {
                EmptyStateView(symbol: "square.stack.3d.up.slash",
                               title: L10n.t("repos.empty.title"),
                               message: L10n.t("repos.empty.message"),
                               actionTitle: L10n.t("repos.create"),
                               action: { isCreating = true })
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateRepositoryView { created in
                viewModel.insert(created)
            }
            .environmentObject(environment)
        }
        .task {
            await viewModel.loadFirstPageIfNeeded()
        }
    }
}
