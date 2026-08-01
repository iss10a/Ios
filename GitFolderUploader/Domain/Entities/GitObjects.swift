//
//  GitObjects.swift
//  GitFolderUploader
//
//  Domain models mirroring the low level Git Data API. Uploading a folder is
//  done through these objects (blob -> tree -> commit -> ref) rather than the
//  Contents API, because a single commit can carry thousands of files.
//

import Foundation

/// A `refs/heads/...` pointer.
struct GitReference: Hashable {
    let ref: String
    let sha: String

    /// Branch name for a `refs/heads/x` reference.
    var branchName: String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }
}

/// A commit object.
struct GitCommit: Hashable {
    let sha: String
    let message: String
    let treeSHA: String
    let parentSHAs: [String]
    let authorName: String?
    let authorDate: Date?
    let htmlURL: URL?
}

/// One entry in a Git tree.
struct TreeEntry: Hashable {

    /// Git file modes we emit.
    enum Mode: String {
        case file = "100644"
        case executable = "100755"
        case subdirectory = "040000"
        case submodule = "160000"
        case symlink = "120000"
    }

    let path: String
    let mode: String
    /// `blob`, `tree` or `commit`.
    let type: String
    let sha: String?
    let size: Int?

    var isBlob: Bool { type == "blob" }

    static func blob(path: String, sha: String, executable: Bool = false) -> TreeEntry {
        TreeEntry(path: path,
                  mode: (executable ? Mode.executable : Mode.file).rawValue,
                  type: "blob",
                  sha: sha,
                  size: nil)
    }

    /// A `nil` SHA tells GitHub to delete the path from the base tree.
    static func deletion(path: String) -> TreeEntry {
        TreeEntry(path: path, mode: Mode.file.rawValue, type: "blob", sha: nil, size: nil)
    }
}

/// A recursively expanded tree.
struct GitTree {
    let sha: String
    let entries: [TreeEntry]
    /// GitHub sets this when the tree exceeded the response limit.
    let isTruncated: Bool

    /// Fast lookup of blob SHA by path — the basis of "skip unchanged files".
    func blobIndex() -> [String: String] {
        var index: [String: String] = [:]
        index.reserveCapacity(entries.count)
        for entry in entries where entry.isBlob {
            if let sha = entry.sha { index[entry.path] = sha }
        }
        return index
    }
}
