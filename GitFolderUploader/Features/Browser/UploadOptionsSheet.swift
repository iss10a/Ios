//
//  UploadOptionsSheet.swift
//  GitFolderUploader
//
//  The review step between picking files or folders and queueing the upload.
//
//  It scans everything that was picked, shows the file count, the total size
//  and every file name, lets the user untick or delete individual files before
//  anything is transferred, and resolves collisions with the destination.
//

import SwiftUI

@MainActor
final class UploadStagingViewModel: ObservableObject {

    // Staging
    @Published private(set) var files: [UploadFileItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var warnings: [String] = []
    @Published var errorMessage: String?

    /// Relative paths the user has unticked. They stay in the list, greyed out.
    @Published var excluded: Set<String> = []

    // Destination
    // Default off. Turning it on nests the whole project one level deep, and
    // tools that only ever look at the repository root — Codemagic reads
    // `codemagic.yaml` there, Flutter needs `pubspec.yaml` there, GitHub
    // Actions reads `.github/workflows/` there — then see nothing at all.
    // Pushing from a computer lands files at the root, which is why the same
    // project builds from a desktop clone and not from here.
    @Published var placeInsideFolder = false
    @Published var customPath: String = ""
    @Published var commitMessage: String = ""
    @Published var conflictPolicy: ConflictPolicy = .replace

    // Conflicts
    @Published private(set) var isCheckingConflicts = false
    @Published private(set) var conflictPaths: Set<String> = []
    @Published private(set) var identicalPaths: Set<String> = []

    let sources: [UploadSource]
    let repository: Repository
    let branch: String
    let currentPath: String

    private let environment: AppEnvironment
    private var conflictTask: Task<Void, Never>?

    init(sources: [UploadSource],
         repository: Repository,
         branch: String,
         currentPath: String,
         environment: AppEnvironment? = nil) {
        self.sources = sources
        self.repository = repository
        self.branch = branch
        self.currentPath = currentPath
        self.environment = environment ?? .shared
    }

    func cancelPendingWork() {
        conflictTask?.cancel()
        conflictTask = nil
    }

    // MARK: - Derived

    /// True when a single folder was picked, which is when offering "put it in
    /// a folder of its own" makes sense.
    var isSingleFolder: Bool { sources.count == 1 && sources[0].isFolder }

    var primaryName: String {
        if sources.count == 1 { return sources[0].displayName }
        return L10n.format("upload.options.items", sources.count)
    }

    var includedFiles: [UploadFileItem] {
        files.filter { !excluded.contains($0.relativePath) }
    }

    var includedCount: Int { includedFiles.count }

    var includedBytes: Int { includedFiles.reduce(0) { $0 + $1.size } }

    var identicalCount: Int {
        includedFiles.filter { identicalPaths.contains($0.relativePath) }.count
    }

    var conflictCount: Int {
        includedFiles.filter { conflictPaths.contains($0.relativePath) }.count
    }

    var canStart: Bool { !isScanning && includedCount > 0 }

    /// Files that only work when they sit at the repository root.
    private static let rootAnchoredNames: Set<String> = [
        "codemagic.yaml", "codemagic.yml",
        "pubspec.yaml", "pubspec.yml",
        "package.json", "Package.swift", "Cargo.toml",
        "Gemfile", "requirements.txt", "pyproject.toml",
        "Dockerfile", "docker-compose.yml",
        "build.gradle", "settings.gradle", "pom.xml",
        ".gitignore", "analysis_options.yaml"
    ]

    /// Names of root-anchored files that this upload would bury in a subfolder.
    ///
    /// Warning about it here is the difference between a build that works and
    /// half an hour of wondering why the CI says there is no configuration.
    var misplacedRootFiles: [String] {
        guard !resolvedDestination.isEmpty else { return [] }
        return includedFiles.compactMap { file in
            let name = (file.relativePath as NSString).lastPathComponent
            let isTopLevel = !file.relativePath.contains("/")
            guard isTopLevel, Self.rootAnchoredNames.contains(name) else { return nil }
            return name
        }
    }

    /// Destination the files will land under.
    var resolvedDestination: String {
        let trimmedCustom = customPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !trimmedCustom.isEmpty { return trimmedCustom }
        if isSingleFolder && placeInsideFolder {
            return FileSystemScanner.joinRemote(prefix: currentPath,
                                                relativePath: sources[0].displayName)
        }
        return currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var defaultCommitMessage: String {
        L10n.format("upload.options.default_message", primaryName)
    }

    // MARK: - Actions

    func scan() async {
        guard files.isEmpty, !isScanning else { return }
        isScanning = true
        scannedCount = 0
        defer { isScanning = false }

        do {
            let staged = try await UploadStaging.stage(sources: sources)
            files = staged.files
            var notes: [String] = []
            if !staged.oversized.isEmpty {
                notes.append(L10n.t("upload.warning.oversized") + " "
                             + staged.oversized.prefix(5).joined(separator: ", "))
            }
            if !staged.unavailableSources.isEmpty {
                notes.append(L10n.t("upload.error.sources_unavailable") + " "
                             + staged.unavailableSources.joined(separator: ", "))
            }
            warnings = notes
            if commitMessage.isEmpty { commitMessage = defaultCommitMessage }
            await checkConflicts()
        } catch {
            errorMessage = FileBrowserViewModel.describe(error)
        }
    }

    /// Looks at the destination and records which files already exist there.
    func checkConflicts() async {
        conflictTask?.cancel()
        guard !files.isEmpty else { return }

        let root = resolvedDestination
        let ref = repository.ref
        let branchName = branch
        let snapshot = files

        isCheckingConflicts = true
        let task = Task { [weak self] in
            defer { Task { @MainActor in self?.isCheckingConflicts = false } }
            guard let self = self else { return }
            do {
                let marked = try await self.remoteMarked(files: snapshot,
                                                         ref: ref,
                                                         branch: branchName,
                                                         root: root)
                guard !Task.isCancelled else { return }
                self.conflictPaths = Set(marked.filter { $0.hasConflict }.map { $0.relativePath })
                self.identicalPaths = Set(marked.filter { $0.state == .skipped }.map { $0.relativePath })
            } catch {
                // Offline or no access: conflicts are re-checked at upload time,
                // so this is informational only and never blocks the user.
                guard !Task.isCancelled else { return }
                self.conflictPaths = []
                self.identicalPaths = []
            }
        }
        conflictTask = task
        await task.value
    }

    private func remoteMarked(files: [UploadFileItem],
                              ref: RepoRef,
                              branch: String,
                              root: String) async throws -> [UploadFileItem] {
        let reference = try await environment.gitData.reference(ref, branch: branch)
        let commit = try await environment.gitData.commit(ref, sha: reference.sha)
        let tree = try await environment.gitData.tree(ref, sha: commit.treeSHA, recursive: true)
        return UploadStaging.markConflicts(files: files,
                                           remoteIndex: tree.blobIndex(),
                                           remoteRoot: root)
    }

    func selectAll() { excluded.removeAll() }

    func deselectAll() { excluded = Set(files.map { $0.relativePath }) }

    func toggle(_ file: UploadFileItem) {
        if excluded.contains(file.relativePath) {
            excluded.remove(file.relativePath)
        } else {
            excluded.insert(file.relativePath)
        }
    }

    func isIncluded(_ file: UploadFileItem) -> Bool { !excluded.contains(file.relativePath) }

    /// Permanently drops files from the staged list.
    func remove(at offsets: IndexSet, in visible: [UploadFileItem]) {
        let doomed = Set(offsets.map { visible[$0].relativePath })
        files.removeAll { doomed.contains($0.relativePath) }
        excluded.subtract(doomed)
        conflictPaths.subtract(doomed)
        identicalPaths.subtract(doomed)
    }

    /// Builds the job that goes into the queue.
    func makeJob() -> UploadJob {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return UploadJob(repo: repository.ref,
                         branch: branch,
                         remoteRoot: resolvedDestination,
                         commitMessage: message.isEmpty ? defaultCommitMessage : message,
                         sources: sources,
                         displayName: primaryName,
                         conflictPolicy: conflictPolicy,
                         files: includedFiles)
    }
}

struct UploadOptionsSheet: View {

    /// Called with the fully prepared job.
    var onConfirm: (UploadJob) -> Void

    @StateObject private var viewModel: UploadStagingViewModel
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showsAllFiles = false

    /// Long lists are truncated in the sheet; the queue's detail screen shows
    /// every entry once the job is running.
    private let previewLimit = 200

    init(sources: [UploadSource],
         repository: Repository,
         branch: String,
         currentPath: String,
         onConfirm: @escaping (UploadJob) -> Void) {
        self.onConfirm = onConfirm
        _viewModel = StateObject(wrappedValue: UploadStagingViewModel(sources: sources,
                                                                      repository: repository,
                                                                      branch: branch,
                                                                      currentPath: currentPath))
    }

    private var visibleFiles: [UploadFileItem] {
        showsAllFiles ? viewModel.files : Array(viewModel.files.prefix(previewLimit))
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                destinationSection
                if viewModel.conflictCount > 0 { conflictSection }
                commitSection
                filesSection
            }
            .navigationTitle(L10n.t("upload.options.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("upload.options.start")) {
                        onConfirm(viewModel.makeJob())
                        dismiss()
                    }
                    .disabled(!viewModel.canStart)
                }
            }
            .task { await viewModel.scan() }
            // Re-checking on the whole form keeps `Section` semantics intact.
            .onChange(of: viewModel.customPath) { _ in
                Task { await viewModel.checkConflicts() }
            }
            .onChange(of: viewModel.placeInsideFolder) { _ in
                Task { await viewModel.checkConflicts() }
            }
            .onDisappear { viewModel.cancelPendingWork() }
            .errorAlert($viewModel.errorMessage)
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section(L10n.t("upload.options.source")) {
            DetailRow(title: L10n.t("upload.options.selection"), value: viewModel.primaryName)
            DetailRow(title: L10n.t("upload.options.repository"), value: viewModel.repository.fullName)
            DetailRow(title: L10n.t("upload.options.branch"), value: viewModel.branch)

            if viewModel.isScanning {
                HStack(spacing: Design.spacing) {
                    ProgressView()
                    Text(L10n.t("upload.options.scanning"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                DetailRow(title: L10n.t("upload.options.file_count"),
                          value: "\(viewModel.includedCount)/\(viewModel.files.count)")
                DetailRow(title: L10n.t("upload.options.total_size"),
                          value: Formatters.size(viewModel.includedBytes))
                if viewModel.identicalCount > 0 {
                    DetailRow(title: L10n.t("upload.options.unchanged"),
                              value: "\(viewModel.identicalCount)")
                }
            }

            ForEach(viewModel.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        Section {
            if viewModel.isSingleFolder {
                Toggle(L10n.format("upload.options.place_inside", viewModel.sources[0].displayName),
                       isOn: $viewModel.placeInsideFolder)
                    .disabled(!viewModel.customPath.isEmpty)
            }
            TextField(L10n.t("upload.options.custom_path"), text: $viewModel.customPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(L10n.t("upload.options.destination"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.resolvedDestination.isEmpty
                     ? L10n.t("upload.options.destination_root")
                     : "/" + viewModel.resolvedDestination)
                    .font(.footnote.monospaced())

                if !viewModel.misplacedRootFiles.isEmpty {
                    Label(L10n.format("upload.options.root_warning",
                                      viewModel.misplacedRootFiles.prefix(3).joined(separator: ", ")),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var conflictSection: some View {
        Section {
            Picker(L10n.t("conflict.policy"), selection: $viewModel.conflictPolicy) {
                ForEach(ConflictPolicy.allCases) { policy in
                    Label(L10n.t(policy.titleKey), systemImage: policy.symbol).tag(policy)
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text(L10n.format("conflict.title", viewModel.conflictCount))
        } footer: {
            Text(L10n.t("conflict.hint"))
        }
    }

    private var commitSection: some View {
        Section(L10n.t("upload.options.commit")) {
            TextField(L10n.t("upload.options.message"), text: $viewModel.commitMessage, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        Section {
            if viewModel.isScanning {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if viewModel.files.isEmpty {
                Text(L10n.t("upload.options.no_files"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleFiles) { file in
                    fileRow(file)
                }
                .onDelete { offsets in
                    viewModel.remove(at: offsets, in: visibleFiles)
                }

                if !showsAllFiles && viewModel.files.count > previewLimit {
                    Button(L10n.format("upload.options.show_all", viewModel.files.count)) {
                        showsAllFiles = true
                    }
                }
            }
        } header: {
            HStack {
                Text(L10n.t("upload.options.files"))
                Spacer()
                Button(L10n.t("common.select_all")) { viewModel.selectAll() }
                    .font(.caption)
                    .disabled(viewModel.excluded.isEmpty)
                Text("·").foregroundStyle(.secondary)
                Button(L10n.t("common.deselect_all")) { viewModel.deselectAll() }
                    .font(.caption)
                    .disabled(viewModel.includedCount == 0)
            }
            .textCase(nil)
        } footer: {
            Text(L10n.t("upload.options.files_hint"))
        }
    }

    private func fileRow(_ file: UploadFileItem) -> some View {
        Button {
            viewModel.toggle(file)
        } label: {
            HStack(spacing: Design.spacing) {
                Image(systemName: viewModel.isIncluded(file) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.isIncluded(file) ? Color.brand : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.relativePath)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(viewModel.isIncluded(file) ? Color.primary : Color.secondary)

                    HStack(spacing: 6) {
                        Text(Formatters.size(file.size))
                        if viewModel.conflictPaths.contains(file.relativePath) {
                            Label(L10n.t("conflict.badge"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else if viewModel.identicalPaths.contains(file.relativePath) {
                            Label(L10n.t("upload.options.unchanged_badge"), systemImage: "equal.circle")
                                .foregroundStyle(.blue)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}
