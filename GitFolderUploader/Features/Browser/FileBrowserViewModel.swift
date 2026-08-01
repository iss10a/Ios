//
//  FileBrowserViewModel.swift
//  GitFolderUploader
//
//  Drives one directory level of a repository: listing, branch selection,
//  folder creation, rename/delete, in-repo search, folder upload and download.
//

import Foundation
import SwiftUI

@MainActor
final class FileBrowserViewModel: ObservableObject {

    // MARK: - Identity

    let repository: Repository
    /// Repository-relative directory this view model shows ("" = root).
    let path: String

    // MARK: - State

    @Published private(set) var items: [RepositoryItem] = []
    @Published private(set) var branches: [Branch] = []
    @Published var branch: String
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?

    /// In-repository search.
    @Published var searchText: String = ""
    @Published private(set) var searchResults: [RepositoryItem] = []
    @Published private(set) var isSearching = false
    @Published var searchesContent = false

    /// Folder download.
    @Published private(set) var downloadProgress: DownloadProgress?
    @Published var exportURL: IdentifiableURL?

    /// Non-nil while the review sheet is open for the items just picked.
    @Published var stagedSelection: StagedSelection?

    /// True while picked items are being captured — copying a large folder into
    /// app storage takes a moment and the UI should say so.
    @Published private(set) var isCapturing = false

    private let environment: AppEnvironment
    private var searchTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    init(repository: Repository, path: String = "", branch: String? = nil, environment: AppEnvironment? = nil) {
        self.repository = repository
        self.path = path
        self.branch = branch ?? repository.defaultBranch
        self.environment = environment ?? .shared
    }

    /// Cancels in-flight work. Called from the view's `onDisappear`; `deinit`
    /// cannot touch isolated state on a main-actor class.
    func cancelPendingWork() {
        searchTask?.cancel()
        searchTask = nil
        downloadTask?.cancel()
        downloadTask = nil
    }

    // MARK: - Derived

    var repoRef: RepoRef { repository.ref }

    var title: String {
        path.isEmpty ? repository.name : (path as NSString).lastPathComponent
    }

    /// Breadcrumb components of the current path.
    var breadcrumbs: [String] {
        path.split(separator: "/").map(String.init)
    }

    var isReadOnly: Bool { !repository.hasPushAccess }

    var displayItems: [RepositoryItem] {
        searchText.isEmpty ? items : searchResults
    }

    /// Default destination for a folder dropped here.
    func defaultDestination(for folderName: String) -> String {
        FileSystemScanner.joinRemote(prefix: path, relativePath: folderName)
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await environment.browseContents(repoRef, path: path, branch: branch)
        } catch APIError.notFound {
            // An empty repository has no contents endpoint yet — not an error.
            items = []
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func loadBranches() async {
        guard branches.isEmpty else { return }
        do {
            branches = try await environment.listBranches(repoRef)
        } catch {
            // A missing branch list must not block browsing.
            AppLog.app.error("Branch list failed: \(Self.describe(error))")
        }
    }

    /// Re-reads the current directory from the remote ("pull").
    func pull() async {
        environment.search.invalidate(repoRef, branch: branch)
        await load()
        statusMessage = L10n.t("browser.pulled")
    }

    func switchBranch(to newBranch: String) async {
        guard newBranch != branch else { return }
        branch = newBranch
        searchResults = []
        await load()
    }

    // MARK: - Mutations

    func createFolder(named name: String) async {
        do {
            try await environment.createFolder(repoRef, parentPath: path, name: name, branch: branch)
            statusMessage = L10n.t("browser.folder_created")
            await load()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func rename(_ item: RepositoryItem, to newName: String) async {
        do {
            try await environment.renameEntry(repoRef, item: item, newName: newName, branch: branch)
            environment.search.invalidate(repoRef, branch: branch)
            statusMessage = L10n.t("browser.renamed")
            await load()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func delete(_ item: RepositoryItem) async {
        do {
            try await environment.deleteEntry(repoRef, item: item, branch: branch)
            environment.search.invalidate(repoRef, branch: branch)
            statusMessage = L10n.t("browser.deleted")
            await load()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Search

    /// Debounced search so typing does not fire a request per keystroke.
    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query)
        }
    }

    private func performSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            if searchesContent {
                searchResults = try await environment.searchCode(repoRef, query: query)
            } else {
                searchResults = try await environment.searchFiles(repoRef, branch: branch, query: query)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Upload

    // MARK: - Picking

    /// Turns URLs coming from the document picker or a drop into sources and
    /// opens the review sheet.
    ///
    /// Each URL is classified by asking the file system rather than trusting the
    /// picker, so a folder dropped from the Files app is walked recursively even
    /// when it arrives through the "files" path.
    func stage(urls: [URL]) {
        guard !urls.isEmpty else {
            AppLog.picker.error("stage() called with no URLs")
            return
        }
        AppLog.picker.info("Staging \(urls.count) picked URL(s)")

        isCapturing = true
        Task { [weak self] in
            // Capturing may copy a large tree into app storage, so it runs off
            // the main actor. The picker's grant is process-wide, not
            // thread-local, so it is still valid here.
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> ([UploadSource], [SourceCapture.Failure]) in
                var built: [UploadSource] = []
                var failures: [SourceCapture.Failure] = []

                for url in urls {
                    // `capture` classifies the item itself and copies it into
                    // app storage, so nothing later depends on this grant.
                    switch SourceCapture.capture(url: url, isFolder: url.hasDirectoryPath) {
                    case .success(let source):
                        built.append(source)
                    case .failure(let failure):
                        failures.append(failure)
                    }
                }
                return (built, failures)
            }.value

            guard let self = self else { return }
            self.isCapturing = false
            self.finishStaging(outcome.0, failures: outcome.1)
        }
    }

    /// Accepts items dropped onto the browser, or pasted into it.
    ///
    /// Both routes deliver `NSItemProvider` values rather than plain URLs,
    /// which is the only way a *folder* can cross the app boundary on iOS.
    func acceptProviders(_ providers: [NSItemProvider], origin: String) {
        guard !providers.isEmpty else { return }
        AppLog.picker.info("Received \(providers.count) provider(s) from \(origin)")

        isCapturing = true
        Task { [weak self] in
            let sources = await ItemProviderLoader.loadSources(from: providers)
            guard let self = self else { return }
            self.isCapturing = false
            guard !sources.isEmpty else {
                AppLog.picker.error("\(origin): no provider produced a source")
                self.errorMessage = L10n.t("upload.error.drop_unreadable")
                return
            }
            self.finishStaging(sources, failures: [])
        }
    }

    /// Reads whatever the user copied in the Files app and turns it into an
    /// upload. iOS has no "paste a folder into an app" file operation, so the
    /// paste is intercepted and converted here instead.
    func pasteFromClipboard() {
        let providers = ItemProviderLoader.pasteboardProviders()
        guard !providers.isEmpty else {
            AppLog.picker.error("Paste requested but the pasteboard holds nothing usable")
            errorMessage = L10n.t("upload.error.paste_empty")
            return
        }
        acceptProviders(providers, origin: "paste")
    }

    private func finishStaging(_ sources: [UploadSource], failures: [SourceCapture.Failure]) {
        // Failures carry the real reason, not just a name, so a screenshot of
        // the sheet is enough to diagnose the problem.
        let detail = failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")

        guard !sources.isEmpty else {
            AppLog.picker.error("Nothing usable was staged")
            errorMessage = L10n.t("upload.error.capture_failed") + "\n" + detail
            return
        }
        if !failures.isEmpty {
            statusMessage = L10n.t("upload.error.capture_failed") + "\n" + detail
        }
        let folders = sources.filter { $0.isFolder }.count
        AppLog.picker.info("Staged \(sources.count) source(s), \(folders) folder(s); opening the review sheet")
        stagedSelection = StagedSelection(sources: sources)
    }

    func clearStagedSelection() {
        stagedSelection = nil
    }

    /// Hands a prepared job to the shared queue.
    func enqueue(_ job: UploadJob) {
        environment.uploads.enqueue(job)
        statusMessage = L10n.t("browser.upload_queued")
    }

    // MARK: - Download

    /// Mirrors the current folder locally, then offers it for export.
    func downloadCurrentFolder() {
        downloadTask?.cancel()
        downloadProgress = DownloadProgress()

        let useCase = environment.downloadFolder
        let ref = repoRef
        let branch = self.branch
        let path = self.path
        let name = path.isEmpty ? repository.name : (path as NSString).lastPathComponent

        downloadTask = Task { [weak self] in
            do {
                let url = try await useCase(ref, branch: branch, path: path, folderName: name) { progress in
                    Task { @MainActor in self?.downloadProgress = progress }
                }
                self?.downloadProgress = nil
                self?.exportURL = IdentifiableURL(url: url)
            } catch is CancellationError {
                self?.downloadProgress = nil
            } catch {
                self?.downloadProgress = nil
                self?.errorMessage = FileBrowserViewModel.describe(error)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadProgress = nil
    }

    func clearStatus() {
        statusMessage = nil
    }

    // MARK: - Helpers

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
