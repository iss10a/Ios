//
//  StageUploadUseCase.swift
//  GitFolderUploader
//
//  Everything that happens *before* the first byte is uploaded: turning the
//  picked files and folders into a concrete list the user can review, and
//  working out which of them already exist at the destination.
//
//  The same code runs from the review sheet and from `UploadFolderUseCase`,
//  so a job that is resumed after a relaunch rebuilds an identical file list.
//

import Foundation

/// Result of preparing an upload.
struct StagedUpload {
    var files: [UploadFileItem] = []
    var totalBytes: Int = 0
    /// Files above GitHub's 100 MB blob ceiling; reported, never silently dropped.
    var oversized: [String] = []
    /// Unreadable entries, symlinks and packages.
    var skipped: [String] = []
    /// Sources whose bookmark could not be resolved any more.
    var unavailableSources: [String] = []
}

enum UploadStaging {

    /// Turns stored sources back into live URLs.
    ///
    /// The returned `access` handles must be kept alive for as long as the URLs
    /// are used, and ended afterwards.
    static func resolve(_ sources: [UploadSource])
        -> (plans: [ResolvedSource], access: [SecurityScopedAccess], unavailable: [String]) {

        var plans: [ResolvedSource] = []
        var access: [SecurityScopedAccess] = []
        var unavailable: [String] = []

        // A single picked folder keeps its contents at the destination root,
        // which is what the destination field in the review sheet expects.
        // Any other combination namespaces each folder under its own name so
        // two folders cannot overwrite each other.
        let singleFolder = sources.count == 1 && sources[0].isFolder

        for (index, source) in sources.enumerated() {
            guard let url = liveURL(for: source) else {
                unavailable.append(source.displayName)
                continue
            }
            access.append(SecurityScopedAccess(url: url))

            let prefix: String
            if source.isFolder && !singleFolder {
                prefix = source.displayName
            } else {
                prefix = ""
            }

            plans.append(ResolvedSource(index: index,
                                        url: url,
                                        isFolder: source.isFolder,
                                        remotePrefix: prefix))
        }

        return (plans, access, unavailable)
    }

    /// Resolves a stored source back to a usable URL.
    ///
    /// Imported sources live inside the sandbox, so they are simply used as is.
    /// In-place sources go through their bookmark; the raw path is only a last
    /// resort, and it is checked *while holding* security-scoped access —
    /// `fileExists` on an out-of-sandbox path always answers `false` without it,
    /// which is what previously made picked folders look like they had vanished.
    private static func liveURL(for source: UploadSource) -> URL? {
        if source.isImported {
            let url = URL(fileURLWithPath: source.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                AppLog.picker.error("[\(source.displayName)] imported copy is gone")
                return nil
            }
            return url
        }

        // Legacy path: jobs persisted before imports became the default may
        // still carry a bookmark.
        if let bookmark = source.bookmark,
           let resolved = try? FolderBookmark.resolve(bookmark) {
            AppLog.picker.info("[\(source.displayName)] resolved from a legacy bookmark")
            return resolved.url
        }

        let fallback = URL(fileURLWithPath: source.path)
        let scoped = fallback.startAccessingSecurityScopedResource()
        defer { if scoped { fallback.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: fallback.path) { return fallback }

        AppLog.picker.error("[\(source.displayName)] could not be resolved by bookmark or path")
        return nil
    }

    /// Scans every source, computing each file's Git blob SHA-1 locally.
    ///
    /// Runs off the main actor: hashing a large folder is CPU bound and would
    /// otherwise freeze the review sheet.
    static func stage(sources: [UploadSource],
                      progress: (@Sendable (Int) -> Void)? = nil) async throws -> StagedUpload {

        let (plans, access, unavailable) = resolve(sources)
        defer { access.forEach { $0.end() } }

        guard !plans.isEmpty else {
            var empty = StagedUpload()
            empty.unavailableSources = unavailable
            return empty
        }

        let scan = try await Task.detached(priority: .userInitiated) {
            try FileSystemScanner.scan(sources: plans, progress: progress)
        }.value

        var staged = StagedUpload()
        staged.oversized = scan.oversized
        staged.skipped = scan.skipped
        staged.unavailableSources = unavailable
        staged.totalBytes = scan.totalBytes
        staged.files = scan.files.map {
            UploadFileItem(relativePath: $0.relativePath,
                           localPath: $0.absolutePath,
                           size: $0.size,
                           gitSHA: $0.gitSHA,
                           sourceIndex: $0.sourceIndex)
        }
        return staged
    }

    /// Marks files whose destination path already holds *different* content.
    ///
    /// Byte-identical files are not conflicts: they are marked `.skipped`
    /// straight away, which is what makes re-uploading a large folder fast.
    ///
    /// - Returns: The updated files.
    static func markConflicts(files: [UploadFileItem],
                              remoteIndex: [String: String],
                              remoteRoot: String) -> [UploadFileItem] {

        var updated = files
        for index in updated.indices {
            let path = updated[index].remotePath(under: remoteRoot)
            guard let remoteSHA = remoteIndex[path] else {
                updated[index].hasConflict = false
                continue
            }
            if remoteSHA == updated[index].gitSHA {
                updated[index].hasConflict = false
                if updated[index].state == .pending {
                    updated[index].state = .skipped
                    updated[index].remoteBlobSHA = updated[index].gitSHA
                }
            } else {
                updated[index].hasConflict = true
            }
        }
        return updated
    }

    /// Applies the chosen policy to every conflicting file.
    ///
    /// - `replace` leaves the file alone; the new blob simply wins.
    /// - `skip` marks it skipped and clears its blob SHA so it is left out of
    ///   the tree entirely, which keeps the remote copy intact.
    /// - `rename` gives it a free path next to the existing file.
    static func applyPolicy(_ policy: ConflictPolicy,
                            to files: [UploadFileItem],
                            remoteIndex: [String: String],
                            remoteRoot: String) -> [UploadFileItem] {

        var updated = files
        var taken = Set(remoteIndex.keys)
        for file in updated {
            taken.insert(file.remotePath(under: remoteRoot))
        }

        for index in updated.indices where updated[index].hasConflict {
            switch policy {
            case .replace:
                updated[index].renamedRelativePath = nil
                if updated[index].state == .skipped {
                    updated[index].state = .pending
                    updated[index].remoteBlobSHA = nil
                }

            case .skip:
                updated[index].state = .skipped
                updated[index].remoteBlobSHA = nil
                updated[index].renamedRelativePath = nil

            case .rename:
                let original = updated[index].relativePath
                let currentRemote = FileSystemScanner.joinRemote(prefix: remoteRoot,
                                                                 relativePath: original)
                let freeRemote = ConflictNaming.freePath(for: currentRemote, taken: taken)
                taken.insert(freeRemote)

                // Translate the free *remote* path back into a relative one.
                let trimmedRoot = remoteRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                var relative = freeRemote
                if !trimmedRoot.isEmpty, relative.hasPrefix(trimmedRoot + "/") {
                    relative = String(relative.dropFirst(trimmedRoot.count + 1))
                }
                updated[index].renamedRelativePath = relative
                if updated[index].state == .skipped {
                    updated[index].state = .pending
                    updated[index].remoteBlobSHA = nil
                }
            }
        }
        return updated
    }
}
