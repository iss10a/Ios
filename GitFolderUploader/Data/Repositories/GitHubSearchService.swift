//
//  GitHubSearchService.swift
//  GitFolderUploader
//
//  Two complementary search strategies:
//
//  * `searchFileNames` walks the recursive tree of the current branch. It works
//    on every repository (including brand new and private ones), is not rate
//    limited by the search API, and matches path fragments.
//  * `searchCode` uses GitHub's code index for full-text matches.
//

import Foundation

final class GitHubSearchService: SearchServiceProtocol {

    private let client: HTTPClient
    private let gitData: GitDataServiceProtocol

    /// Cached trees keyed by "owner/name@branch" so repeated queries while the
    /// user types do not re-download a tree with thousands of entries.
    private var treeCache: [String: (sha: String, entries: [TreeEntry])] = [:]
    private let cacheLock = NSLock()

    init(client: HTTPClient, gitData: GitDataServiceProtocol) {
        self.client = client
        self.gitData = gitData
    }

    func searchFileNames(_ ref: RepoRef, branch: String, query: String) async throws -> [RepositoryItem] {
        let entries = try await cachedTree(ref, branch: branch)
        let needle = query.lowercased()

        let matches = entries.filter { entry in
            entry.isBlob && entry.path.lowercased().contains(needle)
        }

        return matches
            .prefix(300)
            .map { entry in
                RepositoryItem(name: (entry.path as NSString).lastPathComponent,
                               path: entry.path,
                               sha: entry.sha ?? "",
                               size: entry.size ?? 0,
                               kind: .file,
                               downloadURL: nil)
            }
            .sorted { $0.path.count < $1.path.count }
    }

    func searchCode(_ ref: RepoRef, query: String) async throws -> [RepositoryItem] {
        let dto: CodeSearchDTO = try await client.send(GitHubEndpoints.searchCode(ref, query: query))
        return dto.items.map { $0.toDomain() }
    }

    /// Clears the cached tree for a repository, e.g. after an upload.
    func invalidate(_ ref: RepoRef, branch: String) {
        withCacheLock { $0.removeValue(forKey: key(ref, branch)) }
    }

    // MARK: - Private

    /// Synchronous, scoped access to the cache.
    ///
    /// `NSLock.lock()` is unavailable from an `async` context, so every caller
    /// goes through this non-async helper instead of locking inline.
    @discardableResult
    private func withCacheLock<T>(_ body: (inout [String: (sha: String, entries: [TreeEntry])]) -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body(&treeCache)
    }

    private func key(_ ref: RepoRef, _ branch: String) -> String {
        "\(ref.fullName)@\(branch)"
    }

    private func cachedTree(_ ref: RepoRef, branch: String) async throws -> [TreeEntry] {
        let head = try await gitData.reference(ref, branch: branch)

        let cached = withCacheLock { $0[key(ref, branch)] }

        if let cached = cached, cached.sha == head.sha {
            return cached.entries
        }

        let commit = try await gitData.commit(ref, sha: head.sha)
        let tree = try await gitData.tree(ref, sha: commit.treeSHA, recursive: true)

        withCacheLock { $0[key(ref, branch)] = (head.sha, tree.entries) }

        return tree.entries
    }
}
