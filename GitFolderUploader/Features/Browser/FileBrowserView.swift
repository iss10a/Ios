//
//  FileBrowserView.swift
//  GitFolderUploader
//
//  One directory level of a repository. The same view is pushed recursively as
//  the user drills down, so the whole tree is navigable with a single screen.
//

import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @StateObject private var viewModel: FileBrowserViewModel

    /// One picker presentation, one mode. Two `.fileImporter` modifiers on the
    /// same view silently collapse into one, which is why folders never opened
    /// their own picker before.
    @State private var pickerMode: DocumentPickerMode?
    @State private var isDropTargeted = false
    @State private var isShowingBranches = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RepositoryItem?
    @State private var renameValue = ""
    @State private var deleteTarget: RepositoryItem?

    init(repository: Repository, path: String = "", branch: String? = nil) {
        _viewModel = StateObject(wrappedValue: FileBrowserViewModel(repository: repository,
                                                                    path: path,
                                                                    branch: branch))
    }

    var body: some View {
        List {
            if let message = viewModel.errorMessage {
                Section {
                    ErrorBanner(message: message) { Task { await viewModel.load() } }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if let progress = viewModel.downloadProgress {
                Section {
                    downloadRow(progress)
                }
            }

            Section {
                ForEach(viewModel.displayItems) { item in
                    row(for: item)
                }
            } header: {
                if !viewModel.searchText.isEmpty {
                    Text(L10n.format("browser.search.results", viewModel.displayItems.count))
                } else if !viewModel.path.isEmpty {
                    Text("/" + viewModel.path).font(.caption.monospaced())
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: L10n.t("browser.search.prompt"))
        .refreshable { await viewModel.pull() }
        .toolbar { toolbarContent }
        // Drag & drop straight from the Files app.
        //
        // `dropDestination(for: URL.self)` is not used here: its `Transferable`
        // conformance resolves a plain file URL and drops folders on the floor.
        // Accepting raw item providers and declaring `UTType.folder` first is
        // what makes a dragged folder arrive intact.
        .onDrop(of: [UTType.folder, UTType.fileURL, UTType.item],
                isTargeted: $isDropTargeted) { providers in
            guard !viewModel.isReadOnly else { return false }
            viewModel.acceptProviders(providers, origin: "drag & drop")
            return true
        }
        .overlay { overlayContent }
        .overlay { dropHighlight }
        .overlay {
            if viewModel.isCapturing {
                LoadingView(title: L10n.t("upload.pick.importing"))
                    .background(.ultraThinMaterial)
            }
        }
        .onChange(of: viewModel.searchText) { _ in viewModel.scheduleSearch() }
        .onChange(of: viewModel.searchesContent) { _ in viewModel.scheduleSearch() }
        .task {
            await viewModel.load()
            await viewModel.loadBranches()
        }
        .sheet(item: $pickerMode) { mode in
            DocumentPicker(mode: mode) { urls in
                pickerMode = nil
                viewModel.stage(urls: urls)
            } onCancel: {
                pickerMode = nil
            }
            .ignoresSafeArea()
        }
        .sheet(item: $viewModel.stagedSelection) { selection in
            UploadOptionsSheet(sources: selection.sources,
                               repository: viewModel.repository,
                               branch: viewModel.branch,
                               currentPath: viewModel.path) { job in
                viewModel.enqueue(job)
            }
        }
        .sheet(isPresented: $isShowingBranches) {
            BranchesView(repository: viewModel.repository,
                         selectedBranch: Binding(get: { viewModel.branch },
                                                 set: { newValue in
                                                     Task { await viewModel.switchBranch(to: newValue) }
                                                 }))
                .environmentObject(environment)
        }
        .sheet(item: $viewModel.exportURL) { export in
            DocumentExporter(url: export.url) { viewModel.exportURL = nil }
        }
        .alert(L10n.t("browser.new_folder"), isPresented: $isCreatingFolder) {
            TextField(L10n.t("browser.folder_name"), text: $newFolderName)
                .textInputAutocapitalization(.never)
            Button(L10n.t("common.cancel"), role: .cancel) {}
            Button(L10n.t("common.create")) {
                let name = newFolderName
                newFolderName = ""
                Task { await viewModel.createFolder(named: name) }
            }
        } message: {
            Text(L10n.t("browser.new_folder.hint"))
        }
        .alert(L10n.t("browser.rename"), isPresented: Binding(get: { renameTarget != nil },
                                                              set: { if !$0 { renameTarget = nil } })) {
            TextField(L10n.t("browser.new_name"), text: $renameValue)
                .textInputAutocapitalization(.never)
            Button(L10n.t("common.cancel"), role: .cancel) { renameTarget = nil }
            Button(L10n.t("common.save")) {
                if let target = renameTarget {
                    let value = renameValue
                    renameTarget = nil
                    Task { await viewModel.rename(target, to: value) }
                }
            }
        }
        .confirmationDialog(L10n.t("browser.delete.confirm"),
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.t("common.delete"), role: .destructive) {
                if let target = deleteTarget {
                    deleteTarget = nil
                    Task { await viewModel.delete(target) }
                }
            }
            Button(L10n.t("common.cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map { L10n.format("browser.delete.message", $0.path) } ?? "")
        }
        .overlay(alignment: .bottom) { statusToast }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: RepositoryItem) -> some View {
        Group {
            if item.isDirectory {
                NavigationLink {
                    FileBrowserView(repository: viewModel.repository,
                                    path: item.path,
                                    branch: viewModel.branch)
                } label: {
                    itemLabel(item)
                }
            } else {
                NavigationLink {
                    FileDetailView(repository: viewModel.repository,
                                   item: item,
                                   branch: viewModel.branch)
                } label: {
                    itemLabel(item)
                }
            }
        }
        .contextMenu {
            if !viewModel.isReadOnly {
                Button {
                    renameValue = item.name
                    renameTarget = item
                } label: {
                    Label(L10n.t("browser.rename"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteTarget = item
                } label: {
                    Label(L10n.t("common.delete"), systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if !viewModel.isReadOnly {
                Button(role: .destructive) { deleteTarget = item } label: {
                    Label(L10n.t("common.delete"), systemImage: "trash")
                }
                Button {
                    renameValue = item.name
                    renameTarget = item
                } label: {
                    Label(L10n.t("browser.rename"), systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
    }

    private func itemLabel(_ item: RepositoryItem) -> some View {
        HStack(spacing: Design.spacing) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(Color.icon(for: item.isDirectory))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if !viewModel.searchText.isEmpty {
                    Text(item.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if item.size > 0 {
                    Text(Formatters.size(item.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func downloadRow(_ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: Design.tightSpacing) {
            ProgressBar(fraction: progress.fraction,
                        caption: "\(progress.completedFiles)/\(progress.totalFiles) · "
                            + Formatters.size(progress.completedBytes))
            Button(L10n.t("common.cancel"), role: .cancel) { viewModel.cancelDownload() }
                .font(.footnote)
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // A dedicated, always-visible Upload control rather than an entry
        // buried in the overflow menu.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    pickerMode = .files
                } label: {
                    Label(L10n.t("upload.pick.files"), systemImage: "doc.on.doc")
                }
                Button {
                    pickerMode = .folders
                } label: {
                    Label(L10n.t("upload.pick.folder"), systemImage: "folder")
                }
                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label(L10n.t("upload.pick.paste"), systemImage: "doc.on.clipboard")
                }
                Section {
                    Text(L10n.t("upload.pick.drop_hint"))
                }
            } label: {
                Label(L10n.t("upload.pick.title"), systemImage: "arrow.up.circle.fill")
            }
            .disabled(viewModel.isReadOnly)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section {
                    Button {
                        isShowingBranches = true
                    } label: {
                        Label(viewModel.branch, systemImage: "arrow.triangle.branch")
                    }
                    Button {
                        Task { await viewModel.pull() }
                    } label: {
                        Label(L10n.t("browser.pull"), systemImage: "arrow.clockwise")
                    }
                }

                Section {
                    Button {
                        newFolderName = ""
                        isCreatingFolder = true
                    } label: {
                        Label(L10n.t("browser.new_folder"), systemImage: "folder.badge.plus")
                    }
                    .disabled(viewModel.isReadOnly)

                    Button {
                        viewModel.downloadCurrentFolder()
                    } label: {
                        Label(L10n.t("browser.download_folder"), systemImage: "arrow.down.doc")
                    }
                    .disabled(viewModel.downloadProgress != nil)
                }

                Section {
                    Toggle(isOn: $viewModel.searchesContent) {
                        Label(L10n.t("browser.search.content"), systemImage: "text.magnifyingglass")
                    }
                }
            } label: {
                Label(L10n.t("common.actions"), systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            LoadingView()
        } else if viewModel.isSearching {
            LoadingView(title: L10n.t("browser.searching"))
        } else if viewModel.displayItems.isEmpty && !viewModel.isLoading {
            if viewModel.searchText.isEmpty {
                EmptyStateView(symbol: "folder",
                               title: L10n.t("browser.empty.title"),
                               message: L10n.t("browser.empty.message"),
                               actionTitle: viewModel.isReadOnly ? nil : L10n.t("upload.pick.title"),
                               action: viewModel.isReadOnly ? nil : { pickerMode = .folders })
            } else {
                EmptyStateView(symbol: "magnifyingglass",
                               title: L10n.t("browser.no_results.title"),
                               message: L10n.t("browser.no_results.message"))
            }
        }
    }

    @ViewBuilder
    private var statusToast: some View {
        if let status = viewModel.statusMessage {
            Text(status)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    viewModel.clearStatus()
                }
        }
    }

    // MARK: - Actions

    /// Visual feedback while something is being dragged over the list.
    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .background(
                    RoundedRectangle(cornerRadius: Design.cornerRadius)
                        .fill(Color.brand.opacity(0.08))
                )
                .overlay {
                    Label(L10n.t("upload.drop.here"), systemImage: "arrow.down.doc.fill")
                        .font(.headline)
                        .foregroundStyle(Color.brand)
                }
                .padding(8)
                .allowsHitTesting(false)
        }
    }
}
