//
//  FileDetailView.swift
//  GitFolderUploader
//
//  Previews a single file (text or image), and offers rename / delete / export.
//

import SwiftUI
import UIKit

@MainActor
final class FileDetailViewModel: ObservableObject {

    @Published private(set) var content: FileContent?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var exportURL: IdentifiableURL?

    let repository: Repository
    let item: RepositoryItem
    let branch: String

    private let environment: AppEnvironment

    init(repository: Repository,
         item: RepositoryItem,
         branch: String,
         environment: AppEnvironment? = nil) {
        self.repository = repository
        self.item = item
        self.branch = branch
        self.environment = environment ?? .shared
    }

    var canPreview: Bool { item.isProbablyText || item.isImage }

    func load() async {
        guard content == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await environment.readFile(repository.ref, path: item.path, branch: branch)
        } catch {
            errorMessage = FileBrowserViewModel.describe(error)
        }
    }

    /// Writes the file to a temporary location so it can be exported.
    func prepareExport() {
        guard let content = content else { return }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(item.name)
            try content.data.write(to: url, options: .atomic)
            exportURL = IdentifiableURL(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FileDetailView: View {

    @StateObject private var viewModel: FileDetailViewModel
    @ObservedObject private var localization = LocalizationManager.shared

    init(repository: Repository, item: RepositoryItem, branch: String) {
        _viewModel = StateObject(wrappedValue: FileDetailViewModel(repository: repository,
                                                                   item: item,
                                                                   branch: branch))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.spacing) {
                metadata

                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if let message = viewModel.errorMessage {
                    ErrorBanner(message: message) { Task { await viewModel.load() } }
                } else if let content = viewModel.content {
                    preview(content)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(viewModel.item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.prepareExport()
                } label: {
                    Label(L10n.t("file.export"), systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.content == nil)
            }
        }
        .sheet(item: $viewModel.exportURL) { export in
            DocumentExporter(url: export.url) { viewModel.exportURL = nil }
        }
        .task { await viewModel.load() }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Design.tightSpacing) {
            DetailRow(title: L10n.t("file.path"), value: viewModel.item.path, monospaced: true)
            DetailRow(title: L10n.t("file.size"), value: Formatters.size(viewModel.item.size))
            DetailRow(title: L10n.t("file.sha"),
                      value: String(viewModel.item.sha.prefix(12)),
                      monospaced: true)
            DetailRow(title: L10n.t("file.branch"), value: viewModel.branch)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Design.cornerRadius))
    }

    @ViewBuilder
    private func preview(_ content: FileContent) -> some View {
        if viewModel.item.isImage, let image = UIImage(data: content.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Design.cornerRadius))
        } else if let text = content.text {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Design.cornerRadius))
        } else {
            EmptyStateView(symbol: "doc.questionmark",
                           title: L10n.t("file.binary.title"),
                           message: L10n.t("file.binary.message"))
        }
    }
}
