//
//  ContentUseCases.swift
//  GitFolderUploader
//
//  Directory listing, folder creation, rename and delete.
//
//  Rename and delete go through the Git Data API rather than the Contents API
//  so that a folder with hundreds of files moves in a *single* commit instead
//  of one commit per file.
//

import Foundation

/// Lists one directory level.
struct BrowseContentsUseCase {
    let service: ContentServiceProtocol

    func callAsFunction(_ ref: RepoRef, path: String, branch: String) async throws -> [RepositoryItem] {
        let items = try await service.listContents(ref, path: path, branch: branch)
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Reads a single file for preview.
struct ReadFileUseCase {
    let service: ContentServiceProtocol

    func callAsFunction(_ ref: RepoRef, path: String, branch: String) async throws -> FileContent {
        try await service.fileContent(ref, path: path, branch: branch)
    }
}

/// Creates a directory.
///
/// Git does not track empty directories, so a `.gitkeep` placeholder is
/// committed — the same convention every Git client uses.
struct CreateFolderUseCase {
    let service: ContentServiceProtocol

    static func validate(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L10n.t("folder.error.empty") }
        if trimmed.contains("/") || trimmed.contains("\\") { return L10n.t("folder.error.slash") }
        if trimmed == "." || trimmed == ".." { return L10n.t("folder.error.name") }
        return nil
    }

    func callAsFunction(_ ref: RepoRef, parentPath: String, name: String, branch: String) async throws {
        if let problem = Self.validate(name: name) {
            throw APIError.validationFailed(problem)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPath = FileSystemScanner.joinRemote(prefix: parentPath, relativePath: trimmed)
        let keepPath = folderPath + "/.gitkeep"
        try await service.putFile(ref,
                                  path: keepPath,
                                  message: "Create folder \(folderPath)",
                                  data: Data(),
                                  existingSHA: nil,
                                  branch: branch)
    }
}

/// Shared plumbing for tree-rewriting operations (rename / delete).
struct TreeMutationUseCase {

    let gitData: GitDataServiceProtocol

    /// Applies `entries` on top of the current branch head and pushes a commit.
    ///
    /// - Returns: The new commit SHA.
    @discardableResult
    func commit(_ ref: RepoRef,
                branch: String,
                message: String,
                entries: [TreeEntry]) async throws -> String {
        guard !entries.isEmpty else { throw APIError.validationFailed(L10n.t("error.nothing_to_commit")) }

        let head = try await gitData.reference(ref, branch: branch)
        let baseCommit = try await gitData.commit(ref, sha: head.sha)

        var treeSHA = baseCommit.treeSHA
        for chunk in entries.chunked(into: 300) {
            treeSHA = try await gitData.createTree(ref, baseTreeSHA: treeSHA, entries: chunk)
        }

        let commit = try await gitData.createCommit(ref,
                                                    message: message,
                                                    treeSHA: treeSHA,
                                                    parentSHAs: [head.sha])
        try await gitData.updateBranch(ref, name: branch, toSHA: commit.sha, force: false)
        return commit.sha
    }

    /// Every blob under `prefix` (inclusive) in the branch head tree.
    func blobs(under prefix: String, ref: RepoRef, branch: String) async throws -> [TreeEntry] {
        let head = try await gitData.reference(ref, branch: branch)
        let baseCommit = try await gitData.commit(ref, sha: head.sha)
        let tree = try await gitData.tree(ref, sha: baseCommit.treeSHA, recursive: true)

        let normalized = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return tree.entries.filter { entry in
            guard entry.isBlob else { return false }
            if normalized.isEmpty { return true }
            return entry.path == normalized || entry.path.hasPrefix(normalized + "/")
        }
    }
}

/// Renames (or moves) a file or a whole folder in one commit.
struct RenameEntryUseCase {
    let gitData: GitDataServiceProtocol

    func callAsFunction(_ ref: RepoRef,
                        item: RepositoryItem,
                        newName: String,
                        branch: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.validationFailed(L10n.t("rename.error.empty")) }
        guard trimmed != item.name else { return }

        let parent = (item.path as NSString).deletingLastPathComponent
        let destination = FileSystemScanner.joinRemote(prefix: parent, relativePath: trimmed)
        let mutation = TreeMutationUseCase(gitData: gitData)

        var entries: [TreeEntry] = []

        if item.isDirectory {
            let existing = try await mutation.blobs(under: item.path, ref: ref, branch: branch)
            guard !existing.isEmpty else { throw APIError.notFound }
            for entry in existing {
                guard let sha = entry.sha else { continue }
                let suffix = String(entry.path.dropFirst(item.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let newPath = suffix.isEmpty ? destination : destination + "/" + suffix
                entries.append(TreeEntry.deletion(path: entry.path))
                entries.append(TreeEntry(path: newPath, mode: entry.mode, type: entry.type, sha: sha, size: nil))
            }
        } else {
            entries.append(TreeEntry.deletion(path: item.path))
            entries.append(TreeEntry.blob(path: destination, sha: item.sha))
        }

        try await mutation.commit(ref,
                                  branch: branch,
                                  message: "Rename \(item.path) to \(destination)",
                                  entries: entries)
    }
}

/// Deletes a file or a folder (recursively) in one commit.
struct DeleteEntryUseCase {
    let gitData: GitDataServiceProtocol

    func callAsFunction(_ ref: RepoRef, item: RepositoryItem, branch: String) async throws {
        let mutation = TreeMutationUseCase(gitData: gitData)
        var entries: [TreeEntry] = []

        if item.isDirectory {
            let existing = try await mutation.blobs(under: item.path, ref: ref, branch: branch)
            guard !existing.isEmpty else { throw APIError.notFound }
            entries = existing.map { TreeEntry.deletion(path: $0.path) }
        } else {
            entries = [TreeEntry.deletion(path: item.path)]
        }

        try await mutation.commit(ref,
                                  branch: branch,
                                  message: "Delete \(item.path)",
                                  entries: entries)
    }
}
