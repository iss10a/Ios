//
//  UploadJob.swift
//  GitFolderUploader
//
//  Persistent description of one "upload this folder" operation.
//
//  The whole model is `Codable` and written to disk after every meaningful
//  state change, which is what makes uploads resumable across app launches,
//  crashes and background suspension.
//

import Foundation

/// Per-file progress inside a job.
struct UploadFileItem: Identifiable, Hashable, Codable {

    enum State: String, Codable {
        case pending
        case uploading
        case uploaded
        /// Remote already had an identical blob — nothing was transferred.
        case skipped
        case failed
    }

    var id: String { relativePath }

    /// Path relative to the selected folder (or the bare file name for a
    /// single picked file). Unique inside a job.
    let relativePath: String
    /// Absolute local path, re-derived from the bookmark on resume.
    var localPath: String
    let size: Int
    /// Locally computed Git blob SHA-1.
    let gitSHA: String
    /// Blob SHA known to exist on the remote (equals `gitSHA` once uploaded).
    var remoteBlobSHA: String?
    var state: State = .pending
    var errorMessage: String?
    var attempts: Int = 0

    /// Index of the `UploadSource` this file came from.
    var sourceIndex: Int = 0
    /// Bytes handed to `URLSession` so far, for the per-file progress bar.
    var bytesSent: Int = 0
    /// Set when the conflict policy is `.rename`; overrides `relativePath`
    /// when the remote path is computed.
    var renamedRelativePath: String?
    /// The remote already holds a *different* file at this path.
    var hasConflict: Bool = false

    /// Destination path inside the repository.
    func remotePath(under root: String) -> String {
        FileSystemScanner.joinRemote(prefix: root,
                                     relativePath: renamedRelativePath ?? relativePath)
    }

    /// 0...1 progress for this single file.
    var fractionCompleted: Double {
        switch state {
        case .uploaded, .skipped: return 1
        case .pending, .failed: return 0
        case .uploading:
            guard size > 0 else { return 0 }
            return min(1, Double(bytesSent) / Double(size))
        }
    }

    /// Name shown in compact rows.
    var name: String { (relativePath as NSString).lastPathComponent }
}

/// Lifecycle of a job.
enum UploadJobState: Codable, Hashable {
    case queued
    case scanning
    case comparing
    case uploadingBlobs
    case buildingTree
    case committing
    case completed(commitSHA: String)
    case paused
    case failed(message: String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .scanning, .comparing, .uploadingBlobs, .buildingTree, .committing: return true
        default: return false
        }
    }

    /// Jobs in these states are picked up again by "resume all".
    var isResumable: Bool {
        switch self {
        case .paused, .failed, .queued: return true
        default: return false
        }
    }

    var titleKey: String {
        switch self {
        case .queued: return "upload.state.queued"
        case .scanning: return "upload.state.scanning"
        case .comparing: return "upload.state.comparing"
        case .uploadingBlobs: return "upload.state.uploading"
        case .buildingTree: return "upload.state.tree"
        case .committing: return "upload.state.committing"
        case .completed: return "upload.state.completed"
        case .paused: return "upload.state.paused"
        case .failed: return "upload.state.failed"
        case .cancelled: return "upload.state.cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .scanning, .comparing: return "magnifyingglass"
        case .uploadingBlobs: return "arrow.up.circle"
        case .buildingTree: return "point.3.connected.trianglepath.dotted"
        case .committing: return "checkmark.seal"
        case .completed: return "checkmark.circle.fill"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}

/// A queued folder upload.
struct UploadJob: Identifiable, Codable, Hashable {

    let id: UUID
    var repo: RepoRef
    var branch: String
    /// Destination prefix inside the repository ("" = repository root).
    var remoteRoot: String
    var commitMessage: String

    /// Everything the user picked: any mix of single files and folders. Each
    /// carries its own security-scoped bookmark so the job survives relaunch.
    var sources: [UploadSource]
    var displayName: String

    /// What to do when the destination already holds a different file.
    var conflictPolicy: ConflictPolicy

    var files: [UploadFileItem]
    var state: UploadJobState
    var createdAt: Date
    var updatedAt: Date

    /// Commit the job started from; used to detect races on the branch.
    var baseCommitSHA: String?
    var resultCommitSHA: String?
    var lastError: String?

    /// When the current run of the transfer started, used for speed and ETA.
    var transferStartedAt: Date?
    /// Bytes already sent before the current run began, so pausing and
    /// resuming does not make the speed reading jump.
    var bytesSentBeforeRun: Int = 0

    init(id: UUID = UUID(),
         repo: RepoRef,
         branch: String,
         remoteRoot: String,
         commitMessage: String,
         sources: [UploadSource],
         displayName: String,
         conflictPolicy: ConflictPolicy = .replace,
         files: [UploadFileItem] = [],
         state: UploadJobState = .queued,
         createdAt: Date = Date()) {
        self.id = id
        self.repo = repo
        self.branch = branch
        self.remoteRoot = remoteRoot
        self.commitMessage = commitMessage
        self.sources = sources
        self.displayName = displayName
        self.conflictPolicy = conflictPolicy
        self.files = files
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - Derived progress

    var totalFiles: Int { files.count }

    var settledFiles: Int {
        files.filter { $0.state == .uploaded || $0.state == .skipped }.count
    }

    var skippedFiles: Int { files.filter { $0.state == .skipped }.count }

    var failedFiles: Int { files.filter { $0.state == .failed }.count }

    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }

    /// Bytes actually sent over the wire (skipped files cost nothing).
    /// Includes the partial progress of files still in flight.
    var transferredBytes: Int {
        files.reduce(0) { total, file in
            switch file.state {
            case .uploaded: return total + file.size
            case .uploading: return total + min(file.bytesSent, file.size)
            default: return total
            }
        }
    }

    /// Bytes that still have to travel, ignoring anything already skipped.
    var remainingBytes: Int {
        max(0, transferableBytes - transferredBytes)
    }

    /// Total size of everything that is not skipped.
    var transferableBytes: Int {
        files.filter { $0.state != .skipped }.reduce(0) { $0 + $1.size }
    }

    var conflictCount: Int { files.filter { $0.hasConflict }.count }

    /// Average bytes per second for the current run, or `nil` before enough
    /// data has moved to make the number meaningful.
    var bytesPerSecond: Double? {
        guard let started = transferStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 1 else { return nil }
        let moved = Double(transferredBytes - bytesSentBeforeRun)
        guard moved > 0 else { return nil }
        return moved / elapsed
    }

    /// Estimated seconds until the transfer finishes.
    var estimatedSecondsRemaining: TimeInterval? {
        guard let speed = bytesPerSecond, speed > 0 else { return nil }
        let remaining = Double(remainingBytes)
        guard remaining > 0 else { return nil }
        return remaining / speed
    }

    /// Files that still have to be uploaded.
    var pendingFiles: [UploadFileItem] {
        files.filter { $0.state == .pending || $0.state == .uploading || $0.state == .failed }
    }

    var pendingBytes: Int {
        files.filter { $0.state == .pending || $0.state == .uploading || $0.state == .failed }
            .reduce(0) { $0 + $1.size }
    }

    /// 0...1 progress used by the UI. Weighted by bytes so a folder holding a
    /// few large files does not appear stuck, and falls back to a file count
    /// when every file is empty.
    var fractionCompleted: Double {
        guard totalFiles > 0 else { return state.isTerminal ? 1 : 0 }
        let transferable = transferableBytes
        guard transferable > 0 else {
            return Double(settledFiles) / Double(totalFiles)
        }
        return min(1, Double(transferredBytes) / Double(transferable))
    }

    var summaryLine: String {
        "\(settledFiles)/\(totalFiles) · " + Formatters.size(totalBytes)
    }
}
