//
//  UploadFolderUseCase.swift
//  GitFolderUploader
//
//  The heart of the app: turns the files and folders the user picked into one
//  Git commit, preserving the exact hierarchy.
//
//  Pipeline
//  --------
//  1. Resolve every source's security-scoped bookmark and scan it. Folders are
//     walked recursively; each file's Git blob SHA-1 is computed locally.
//  2. Read the remote tree once and diff it against those SHAs. Files that
//     already exist with identical content are marked `.skipped` and never
//     transferred. Files that exist with *different* content are conflicts,
//     resolved with the job's `ConflictPolicy`.
//  3. Upload the remaining files as blobs, with bounded concurrency, retries,
//     live per-file byte progress and per-file persistence so an interrupted
//     run resumes exactly where it stopped.
//  4. Build the tree in chunks (chaining `base_tree`) so repositories with
//     thousands of files stay inside GitHub's request limits.
//  5. Create the commit and fast-forward the branch. A concurrent push on the
//     same branch is detected and retried against the new head.
//

import Foundation

/// Tuning knobs for a run.
struct UploadConfiguration {
    /// Simultaneous blob uploads. GitHub tolerates a handful comfortably.
    var concurrency: Int = 4
    /// Maximum tree entries per `POST /git/trees` call.
    var treeChunkSize: Int = 300
    /// Per-file upload attempts before the file is marked failed.
    var maxAttemptsPerFile: Int = 3
    /// Attempts to land the commit when the branch moves underneath us.
    var maxPushAttempts: Int = 3
    /// How often in-flight byte counts are published to the UI.
    var progressTickSeconds: Double = 0.4

    static let `default` = UploadConfiguration()
}

/// Thread-safe scratch pad for bytes reported by `URLSession` delegates.
///
/// The delegates fire on a background queue while the upload loop owns the job
/// value, so the two never touch the same storage directly.
final class UploadProgressBox: @unchecked Sendable {

    private let lock = NSLock()
    private var bytesByFileIndex: [Int: Int] = [:]

    func record(bytes: Int, for fileIndex: Int) {
        lock.lock()
        bytesByFileIndex[fileIndex] = bytes
        lock.unlock()
    }

    func snapshot() -> [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        return bytesByFileIndex
    }

    func clear(fileIndex: Int) {
        lock.lock()
        bytesByFileIndex[fileIndex] = nil
        lock.unlock()
    }
}

/// Executes one `UploadJob`.
///
/// The use case is stateless: all mutable progress lives in the job value that
/// is passed in, mutated, and streamed back through `onUpdate`.
final class UploadFolderUseCase {

    private let gitData: GitDataServiceProtocol
    private let configuration: UploadConfiguration

    init(gitData: GitDataServiceProtocol, configuration: UploadConfiguration = .default) {
        self.gitData = gitData
        self.configuration = configuration
    }

    /// Head of a branch: the commit and the tree it points at.
    private struct Head {
        let commitSHA: String
        let treeSHA: String
    }

    /// Result of one blob upload, carried out of the task group.
    private struct BlobOutcome {
        let index: Int
        let sha: String?
        /// `nil` error with `nil` sha means "cancelled before running".
        let error: String?
    }

    /// Everything the upload task group can hand back.
    private enum GroupEvent {
        case finished(BlobOutcome)
        /// A periodic wake-up so in-flight byte counts reach the UI.
        case tick
    }

    // MARK: - Entry point

    /// Runs the job to completion.
    ///
    /// Already-settled files are honoured, so calling this again on a paused or
    /// failed job resumes instead of restarting.
    ///
    /// - Parameters:
    ///   - job: The job to execute.
    ///   - onUpdate: Invoked whenever the job value changes. The caller is
    ///     expected to persist and publish it.
    /// - Returns: The final job value.
    func execute(job initial: UploadJob, onUpdate: @escaping (UploadJob) -> Void) async -> UploadJob {
        var job = initial

        /// Applies a mutation, stamps the timestamp and notifies the caller.
        func publish(_ mutate: (inout UploadJob) -> Void) {
            mutate(&job)
            job.updatedAt = Date()
            onUpdate(job)
        }

        // Keep security-scoped access alive for the whole run.
        var access: [SecurityScopedAccess] = []
        defer { access.forEach { $0.end() } }

        do {
            // ---- 1. Resolve every picked source ----------------------------
            let resolved = UploadStaging.resolve(job.sources)
            access = resolved.access
            let plans = resolved.plans
            let unavailable = resolved.unavailable

            guard !plans.isEmpty else {
                let names = unavailable.joined(separator: ", ")
                publish {
                    $0.state = .failed(message: L10n.t("upload.error.sources_unavailable") + " " + names)
                }
                return job
            }

            // ---- 2. Scan, or reuse the list built in the review sheet ------
            if job.files.isEmpty || !filesStillOnDisk(job.files) {
                publish { $0.state = .scanning }

                let scan = try FileSystemScanner.scan(sources: plans)
                guard !scan.files.isEmpty else {
                    publish { $0.state = .failed(message: L10n.t("upload.error.empty_folder")) }
                    return job
                }

                let fresh = scan.files.map {
                    UploadFileItem(relativePath: $0.relativePath,
                                   localPath: $0.absolutePath,
                                   size: $0.size,
                                   gitSHA: $0.gitSHA,
                                   sourceIndex: $0.sourceIndex)
                }
                let merged = Self.merge(previous: job.files, fresh: fresh)

                var warnings: [String] = []
                if !scan.oversized.isEmpty {
                    warnings.append(L10n.t("upload.warning.oversized") + " "
                                    + scan.oversized.joined(separator: ", "))
                }
                if !unavailable.isEmpty {
                    warnings.append(L10n.t("upload.error.sources_unavailable") + " "
                                    + unavailable.joined(separator: ", "))
                }
                publish {
                    $0.files = merged
                    $0.lastError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
                }
            }

            try Task.checkCancellation()

            // ---- 3. Diff against the remote tree ---------------------------
            publish { $0.state = .comparing }
            let head = try await currentHead(repo: job.repo, branch: job.branch)
            let headCommit = head?.commitSHA
            publish { $0.baseCommitSHA = headCommit }

            let remoteIndex = try await remoteBlobIndex(repo: job.repo, head: head)
            let policy = job.conflictPolicy
            publish { current in
                var files = UploadStaging.markConflicts(files: current.files,
                                                        remoteIndex: remoteIndex,
                                                        remoteRoot: current.remoteRoot)
                files = UploadStaging.applyPolicy(policy,
                                                  to: files,
                                                  remoteIndex: remoteIndex,
                                                  remoteRoot: current.remoteRoot)
                current.files = files
            }

            try Task.checkCancellation()

            // ---- 4. Upload the remaining blobs -----------------------------
            publish {
                $0.state = .uploadingBlobs
                $0.bytesSentBeforeRun = $0.transferredBytes
                $0.transferStartedAt = Date()
            }
            job = await uploadBlobs(job: job, onUpdate: onUpdate)

            if Task.isCancelled {
                publish { $0.state = .paused }
                return job
            }
            if job.failedFiles > 0 {
                let message = L10n.format("upload.error.files_failed", job.failedFiles)
                publish { $0.state = .failed(message: message) }
                return job
            }

            // ---- 5. Tree + commit + push -----------------------------------
            var entries: [TreeEntry] = []
            entries.reserveCapacity(job.files.count)
            for file in job.files {
                guard let sha = file.remoteBlobSHA else { continue }
                entries.append(TreeEntry.blob(path: file.remotePath(under: job.remoteRoot), sha: sha))
            }

            // Everything was already up to date: nothing to commit is success.
            guard !entries.isEmpty else {
                publish {
                    $0.lastError = nil
                    $0.state = .completed(commitSHA: headCommit ?? "")
                }
                return job
            }

            let commitSHA = try await landCommit(repo: job.repo,
                                                 branch: job.branch,
                                                 message: job.commitMessage,
                                                 entries: entries,
                                                 publish: publish)
            publish {
                $0.resultCommitSHA = commitSHA
                $0.lastError = nil
                $0.state = .completed(commitSHA: commitSHA)
            }
            AppLog.upload.info("Job \(job.id.uuidString) committed \(commitSHA)")
            return job

        } catch is CancellationError {
            publish { $0.state = .paused }
            return job
        } catch APIError.cancelled {
            publish { $0.state = .paused }
            return job
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.upload.error("Job failed: \(message)")
            publish {
                $0.lastError = message
                $0.state = .failed(message: message)
            }
            return job
        }
    }

    // MARK: - Steps

    /// Cheap check for whether a resumed job's recorded paths are still valid.
    private func filesStillOnDisk(_ files: [UploadFileItem]) -> Bool {
        guard let probe = files.first(where: { $0.state != .skipped }) ?? files.first else { return false }
        return FileManager.default.fileExists(atPath: probe.localPath)
    }

    /// Carries progress from a previous run onto a freshly scanned list.
    ///
    /// Files are matched by relative path. A file whose content changed since
    /// the last run is uploaded again rather than trusting the stale blob.
    static func merge(previous: [UploadFileItem], fresh: [UploadFileItem]) -> [UploadFileItem] {
        guard !previous.isEmpty else { return fresh }
        let index = Dictionary(previous.map { ($0.relativePath, $0) },
                               uniquingKeysWith: { first, _ in first })

        return fresh.map { file in
            guard let old = index[file.relativePath], old.gitSHA == file.gitSHA else { return file }
            var carried = file
            carried.state = (old.state == .uploading || old.state == .failed) ? .pending : old.state
            carried.remoteBlobSHA = old.remoteBlobSHA
            carried.renamedRelativePath = old.renamedRelativePath
            carried.hasConflict = old.hasConflict
            carried.attempts = old.attempts
            carried.bytesSent = old.state == .uploaded ? old.size : 0
            return carried
        }
    }

    /// Current branch head, or `nil` when the branch does not exist yet.
    private func currentHead(repo: RepoRef, branch: String) async throws -> Head? {
        do {
            let reference = try await gitData.reference(repo, branch: branch)
            let commit = try await gitData.commit(repo, sha: reference.sha)
            return Head(commitSHA: commit.sha, treeSHA: commit.treeSHA)
        } catch APIError.notFound {
            return nil
        }
    }

    /// Path to blob-SHA map for the whole branch tree.
    private func remoteBlobIndex(repo: RepoRef, head: Head?) async throws -> [String: String] {
        guard let head = head else { return [:] }
        do {
            let tree = try await gitData.tree(repo, sha: head.treeSHA, recursive: true)
            if tree.isTruncated {
                AppLog.upload.info("Remote tree truncated; some files may be re-uploaded")
            }
            return tree.blobIndex()
        } catch APIError.notFound {
            return [:]
        }
    }

    /// Uploads a single file, retrying transient failures and reporting the
    /// bytes written so the UI can draw a real progress bar for it.
    private static func uploadOne(index: Int,
                                  item: UploadFileItem,
                                  repo: RepoRef,
                                  service: GitDataServiceProtocol,
                                  attemptLimit: Int,
                                  progress: UploadProgressBox) async -> BlobOutcome {
        var lastError: String?
        let size = item.size

        for attempt in 0..<attemptLimit {
            if Task.isCancelled {
                progress.clear(fileIndex: index)
                return BlobOutcome(index: index, sha: nil, error: nil)
            }
            do {
                let url = URL(fileURLWithPath: item.localPath)
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let sha = try await service.createBlob(repo, data: data, onProgress: { fraction in
                    progress.record(bytes: Int(fraction * Double(size)), for: index)
                })
                progress.clear(fileIndex: index)
                return BlobOutcome(index: index, sha: sha, error: nil)
            } catch let error as APIError {
                lastError = error.errorDescription
                progress.record(bytes: 0, for: index)
                guard error.isRetryable, attempt < attemptLimit - 1 else { break }
                let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        progress.clear(fileIndex: index)
        return BlobOutcome(index: index, sha: nil, error: lastError ?? L10n.t("error.unknown"))
    }

    /// Uploads every pending file with bounded concurrency.
    private func uploadBlobs(job input: UploadJob, onUpdate: @escaping (UploadJob) -> Void) async -> UploadJob {
        var job = input

        var queue = job.files.indices.filter { index in
            let state = job.files[index].state
            return state == .pending || state == .uploading || state == .failed
        }
        guard !queue.isEmpty else { return job }

        // Smallest first: quick wins land early and progress feels responsive.
        queue.sort { job.files[$0].size < job.files[$1].size }

        let repo = job.repo
        let service = gitData
        let attemptLimit = configuration.maxAttemptsPerFile
        let tick = configuration.progressTickSeconds
        let width = min(configuration.concurrency, queue.count)
        let progress = UploadProgressBox()

        await withTaskGroup(of: GroupEvent.self) { group in
            var cursor = 0
            var inFlight = 0

            while cursor < width {
                let index = queue[cursor]
                let item = job.files[index]
                job.files[index].state = .uploading
                job.files[index].bytesSent = 0
                cursor += 1
                inFlight += 1
                group.addTask {
                    .finished(await UploadFolderUseCase.uploadOne(index: index,
                                                                  item: item,
                                                                  repo: repo,
                                                                  service: service,
                                                                  attemptLimit: attemptLimit,
                                                                  progress: progress))
                }
            }

            // A repeating timer inside the group keeps progress flowing without
            // a second task mutating the job from another thread.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                return .tick
            }

            while inFlight > 0 {
                guard let event = await group.next() else { break }

                switch event {
                case .tick:
                    let snapshot = progress.snapshot()
                    if !snapshot.isEmpty {
                        for (fileIndex, bytes) in snapshot
                        where job.files.indices.contains(fileIndex)
                            && job.files[fileIndex].state == .uploading {
                            job.files[fileIndex].bytesSent = min(bytes, job.files[fileIndex].size)
                        }
                        job.updatedAt = Date()
                        onUpdate(job)
                    }
                    if inFlight > 0 && !Task.isCancelled {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                            return .tick
                        }
                    }

                case .finished(let outcome):
                    inFlight -= 1

                    if let sha = outcome.sha {
                        job.files[outcome.index].remoteBlobSHA = sha
                        job.files[outcome.index].state = .uploaded
                        job.files[outcome.index].bytesSent = job.files[outcome.index].size
                        job.files[outcome.index].errorMessage = nil
                    } else if let error = outcome.error {
                        job.files[outcome.index].state = .failed
                        job.files[outcome.index].errorMessage = error
                        job.files[outcome.index].bytesSent = 0
                        job.files[outcome.index].attempts += 1
                    } else {
                        job.files[outcome.index].state = .pending
                        job.files[outcome.index].bytesSent = 0
                    }

                    job.updatedAt = Date()
                    onUpdate(job)

                    if !Task.isCancelled && cursor < queue.count {
                        let index = queue[cursor]
                        let item = job.files[index]
                        job.files[index].state = .uploading
                        job.files[index].bytesSent = 0
                        cursor += 1
                        inFlight += 1
                        group.addTask {
                            .finished(await UploadFolderUseCase.uploadOne(index: index,
                                                                          item: item,
                                                                          repo: repo,
                                                                          service: service,
                                                                          attemptLimit: attemptLimit,
                                                                          progress: progress))
                        }
                    }
                }
            }
        }
        return job
    }

    /// Builds the tree, creates the commit and fast-forwards the branch.
    ///
    /// Tree creation chains `base_tree` across chunks, so a folder with tens of
    /// thousands of entries is committed without ever sending an oversized body.
    private func landCommit(repo: RepoRef,
                            branch: String,
                            message: String,
                            entries: [TreeEntry],
                            publish: ((inout UploadJob) -> Void) -> Void) async throws -> String {

        guard !entries.isEmpty else {
            throw APIError.validationFailed(L10n.t("error.nothing_to_commit"))
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1

            let head = try await currentHead(repo: repo, branch: branch)

            publish { $0.state = .buildingTree }
            var treeSHA: String? = head?.treeSHA
            for chunk in entries.chunked(into: configuration.treeChunkSize) {
                try Task.checkCancellation()
                treeSHA = try await gitData.createTree(repo, baseTreeSHA: treeSHA, entries: chunk)
            }
            guard let finalTree = treeSHA else { throw APIError.invalidResponse }

            publish { $0.state = .committing }
            let parents: [String] = head.map { [$0.commitSHA] } ?? []
            let commit = try await gitData.createCommit(repo,
                                                        message: message,
                                                        treeSHA: finalTree,
                                                        parentSHAs: parents)

            do {
                if head == nil {
                    _ = try await gitData.createBranch(repo, name: branch, fromSHA: commit.sha)
                } else {
                    try await gitData.updateBranch(repo, name: branch, toSHA: commit.sha, force: false)
                }
                return commit.sha
            } catch let error as APIError {
                // A concurrent push moved the branch: rebuild on the new head.
                let isRace: Bool
                switch error {
                case .validationFailed, .conflict:
                    isRace = true
                default:
                    isRace = false
                }
                guard isRace, attempt < configuration.maxPushAttempts else { throw error }
                AppLog.upload.info("Push rejected, retrying on updated head (attempt \(attempt))")
            }
        }
    }
}
