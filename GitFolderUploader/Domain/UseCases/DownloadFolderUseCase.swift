//
//  DownloadFolderUseCase.swift
//  GitFolderUploader
//
//  Mirrors a repository folder (or the whole repository) onto local disk,
//  preserving the hierarchy, so it can be exported through the Files app.
//

import Foundation

/// Live progress of a download.
struct DownloadProgress {
    var completedFiles: Int = 0
    var totalFiles: Int = 0
    var completedBytes: Int = 0
    var totalBytes: Int = 0

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(completedFiles) / Double(totalFiles)
    }
}

/// Downloads a subtree into a temporary directory.
final class DownloadFolderUseCase {

    private let gitData: GitDataServiceProtocol
    /// Simultaneous blob downloads.
    private let concurrency: Int

    init(gitData: GitDataServiceProtocol, concurrency: Int = 5) {
        self.gitData = gitData
        self.concurrency = concurrency
    }

    private struct Fetched {
        let path: String
        let data: Data?
        let error: String?
    }

    /// Downloads every blob under `path`.
    ///
    /// - Parameters:
    ///   - ref: Repository identity.
    ///   - branch: Branch to read from.
    ///   - path: Subtree prefix; empty means the repository root.
    ///   - folderName: Name of the folder created on disk.
    ///   - onProgress: Called on every completed file.
    /// - Returns: The local directory containing the mirrored hierarchy.
    func callAsFunction(_ ref: RepoRef,
                        branch: String,
                        path: String,
                        folderName: String,
                        onProgress: @escaping (DownloadProgress) -> Void) async throws -> URL {

        let head = try await gitData.reference(ref, branch: branch)
        let commit = try await gitData.commit(ref, sha: head.sha)
        let tree = try await gitData.tree(ref, sha: commit.treeSHA, recursive: true)

        let prefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let blobs = tree.entries.filter { entry in
            guard entry.isBlob, entry.sha != nil else { return false }
            if prefix.isEmpty { return true }
            return entry.path == prefix || entry.path.hasPrefix(prefix + "/")
        }
        guard !blobs.isEmpty else { throw APIError.notFound }

        var progress = DownloadProgress(completedFiles: 0,
                                        totalFiles: blobs.count,
                                        completedBytes: 0,
                                        totalBytes: blobs.reduce(0) { $0 + ($1.size ?? 0) })
        onProgress(progress)

        // Fresh sandbox directory per download so repeated exports never clash.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(Self.sanitize(folderName), isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let service = gitData
        let repo = ref
        let width = min(concurrency, blobs.count)
        var failures: [String] = []

        await withTaskGroup(of: Fetched.self) { group in
            var cursor = 0
            var inFlight = 0

            while cursor < width {
                let entry = blobs[cursor]
                cursor += 1
                inFlight += 1
                group.addTask {
                    await Self.fetch(entry: entry, repo: repo, service: service)
                }
            }

            while inFlight > 0 {
                guard let result = await group.next() else { break }
                inFlight -= 1

                if let data = result.data {
                    let relative = prefix.isEmpty
                        ? result.path
                        : String(result.path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let fileURL = destination.appendingPathComponent(relative.isEmpty ? (result.path as NSString).lastPathComponent : relative)
                    do {
                        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        try data.write(to: fileURL, options: .atomic)
                        progress.completedBytes += data.count
                    } catch {
                        failures.append(result.path)
                    }
                } else {
                    failures.append(result.path)
                }

                progress.completedFiles += 1
                onProgress(progress)

                if !Task.isCancelled && cursor < blobs.count {
                    let entry = blobs[cursor]
                    cursor += 1
                    inFlight += 1
                    group.addTask {
                        await Self.fetch(entry: entry, repo: repo, service: service)
                    }
                }
            }
        }

        if failures.count == blobs.count {
            throw APIError.transport(L10n.t("download.error.all_failed"))
        }
        if !failures.isEmpty {
            AppLog.network.error("Download finished with \(failures.count) failed files")
        }
        return destination
    }

    private static func fetch(entry: TreeEntry,
                              repo: RepoRef,
                              service: GitDataServiceProtocol) async -> Fetched {
        guard let sha = entry.sha else {
            return Fetched(path: entry.path, data: nil, error: "missing sha")
        }
        do {
            let data = try await service.blobData(repo, sha: sha)
            return Fetched(path: entry.path, data: data, error: nil)
        } catch {
            return Fetched(path: entry.path, data: nil, error: error.localizedDescription)
        }
    }

    /// Strips characters that are illegal in a file name.
    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "download" : cleaned
    }
}
