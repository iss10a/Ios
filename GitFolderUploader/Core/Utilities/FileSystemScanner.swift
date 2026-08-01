//
//  FileSystemScanner.swift
//  GitFolderUploader
//
//  Recursively walks a folder picked from the Files app and produces the flat
//  list of files the uploader needs, preserving the relative hierarchy.
//

import Foundation

/// One local file discovered during a scan.
/// A source that has already been resolved to a live URL, together with the
/// prefix its contents should take inside the repository.
struct ResolvedSource {
    /// Index into `UploadJob.sources`.
    let index: Int
    let url: URL
    let isFolder: Bool
    /// Prepended to every relative path produced by this source. Empty means
    /// the source contributes its contents at the destination root.
    let remotePrefix: String

    init(index: Int, url: URL, isFolder: Bool, remotePrefix: String = "") {
        self.index = index
        self.url = url
        self.isFolder = isFolder
        self.remotePrefix = remotePrefix
    }
}

struct ScannedFile: Hashable {
    /// Path relative to the scanned root, using `/` separators (Git style).
    let relativePath: String
    /// Absolute on-disk location.
    let absolutePath: String
    let size: Int
    /// Locally computed Git blob SHA-1, used to skip unchanged files.
    let gitSHA: String
    /// Index of the `UploadSource` that produced this file.
    var sourceIndex: Int = 0

    var url: URL { URL(fileURLWithPath: absolutePath) }
}

/// Aggregate result of a scan.
struct ScanResult {
    var files: [ScannedFile] = []
    var totalBytes: Int = 0
    /// Files rejected because they exceed the GitHub blob limit.
    var oversized: [String] = []
    /// Entries skipped because they are symlinks, packages or unreadable.
    var skipped: [String] = []
}

enum FileSystemScanner {

    /// GitHub rejects blobs larger than 100 MB.
    static let maxBlobBytes = 100 * 1024 * 1024

    /// Directory names never uploaded.
    static let excludedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__pycache__"]

    /// File names never uploaded.
    static let excludedFiles: Set<String> = [".DS_Store", "Thumbs.db", ".localized"]

    /// Recursively enumerates `root`.
    ///
    /// - Parameters:
    ///   - root: Folder to scan. Security-scoped access must already be active.
    ///   - includeHidden: When `false`, dot-files are ignored.
    ///   - progress: Called with the running file count so the UI can show activity.
    /// - Throws: `CancellationError` when the surrounding task is cancelled.
    static func scan(root: URL,
                     includeHidden: Bool = false,
                     progress: ((Int) -> Void)? = nil) throws -> ScanResult {

        var result = ScanResult()
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.path

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .isPackageKey, .isReadableKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: keys,
                                                      options: options) else {
            throw APIError.folderAccessDenied
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()

            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else {
                result.skipped.append(url.lastPathComponent)
                continue
            }
            if values?.isSymbolicLink == true || values?.isReadable == false {
                result.skipped.append(url.lastPathComponent)
                continue
            }
            if excludedFiles.contains(url.lastPathComponent) { continue }

            let size = values?.fileSize ?? 0
            let relative = relativePath(of: url, from: rootPath)
            guard !relative.isEmpty else { continue }

            if size > maxBlobBytes {
                result.oversized.append(relative)
                continue
            }

            let sha: String
            do {
                sha = try GitHash.blobSHA(ofFileAt: url, size: size)
            } catch {
                result.skipped.append(relative)
                continue
            }

            result.files.append(ScannedFile(relativePath: relative,
                                            absolutePath: url.path,
                                            size: size,
                                            gitSHA: sha))
            result.totalBytes += size
            progress?(result.files.count)
        }

        result.files.sort { $0.relativePath < $1.relativePath }
        return result
    }

    /// Converts an absolute URL into a `/` separated path relative to `rootPath`.
    static func relativePath(of url: URL, from rootPath: String) -> String {
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(full.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    /// Scans several picked items at once.
    ///
    /// Folders are walked recursively and keep their internal hierarchy; single
    /// files contribute just their name. Paths that would collide — the same
    /// name coming from two different sources — are given a free name rather
    /// than silently overwriting each other.
    ///
    /// - Throws: `CancellationError` when the surrounding task is cancelled.
    static func scan(sources: [ResolvedSource],
                     includeHidden: Bool = false,
                     progress: ((Int) -> Void)? = nil) throws -> ScanResult {

        var combined = ScanResult()
        var taken = Set<String>()

        for source in sources {
            try Task.checkCancellation()

            if source.isFolder {
                let partial = try scan(root: source.url,
                                       includeHidden: includeHidden,
                                       progress: { _ in progress?(combined.files.count) })
                combined.oversized.append(contentsOf: partial.oversized)
                combined.skipped.append(contentsOf: partial.skipped)

                for file in partial.files {
                    let joined = joinRemote(prefix: source.remotePrefix,
                                            relativePath: file.relativePath)
                    let unique = ConflictNaming.freePath(for: joined, taken: taken)
                    taken.insert(unique)
                    combined.files.append(ScannedFile(relativePath: unique,
                                                      absolutePath: file.absolutePath,
                                                      size: file.size,
                                                      gitSHA: file.gitSHA,
                                                      sourceIndex: source.index))
                    combined.totalBytes += file.size
                    progress?(combined.files.count)
                }
            } else {
                guard let file = try scanSingleFile(at: source.url, result: &combined) else { continue }
                let joined = joinRemote(prefix: source.remotePrefix,
                                        relativePath: source.url.lastPathComponent)
                let unique = ConflictNaming.freePath(for: joined, taken: taken)
                taken.insert(unique)
                combined.files.append(ScannedFile(relativePath: unique,
                                                  absolutePath: file.absolutePath,
                                                  size: file.size,
                                                  gitSHA: file.gitSHA,
                                                  sourceIndex: source.index))
                combined.totalBytes += file.size
                progress?(combined.files.count)
            }
        }

        combined.files.sort { $0.relativePath < $1.relativePath }
        return combined
    }

    /// Hashes one picked file. Returns `nil` when it cannot be uploaded, having
    /// recorded the reason in `result`.
    private static func scanSingleFile(at url: URL, result: inout ScanResult) throws -> ScannedFile? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isReadableKey, .isSymbolicLinkKey]
        let values = try? url.resourceValues(forKeys: keys)

        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              values?.isReadable != false else {
            result.skipped.append(url.lastPathComponent)
            return nil
        }
        if excludedFiles.contains(url.lastPathComponent) { return nil }

        let size = values?.fileSize ?? 0
        if size > maxBlobBytes {
            result.oversized.append(url.lastPathComponent)
            return nil
        }

        do {
            let sha = try GitHash.blobSHA(ofFileAt: url, size: size)
            return ScannedFile(relativePath: url.lastPathComponent,
                               absolutePath: url.path,
                               size: size,
                               gitSHA: sha)
        } catch {
            result.skipped.append(url.lastPathComponent)
            return nil
        }
    }

    /// Joins a remote destination prefix with a relative path, normalising slashes.
    static func joinRemote(prefix: String, relativePath: String) -> String {
        let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let cleanPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if cleanPrefix.isEmpty { return cleanPath }
        if cleanPath.isEmpty { return cleanPrefix }
        return cleanPrefix + "/" + cleanPath
    }
}
