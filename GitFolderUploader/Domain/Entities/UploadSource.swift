//
//  UploadSource.swift
//  GitFolderUploader
//
//  A job is no longer limited to a single picked folder: it carries a list of
//  sources, each of which is either one file or a folder that is walked
//  recursively. Every source keeps its own security-scoped bookmark so the job
//  can be resumed after the app is relaunched.
//

import Foundation

/// One item the user picked in the Files app, dropped onto the app, or added
/// through the document picker.
struct UploadSource: Codable, Hashable, Identifiable {

    enum Kind: String, Codable {
        case file
        case folder
    }

    let id: UUID
    let kind: Kind

    /// Security-scoped bookmark, so access survives relaunching.
    var bookmark: Data?
    /// Last known absolute path; a fallback when the bookmark cannot resolve.
    var path: String
    /// Name shown in the UI.
    var displayName: String

    /// `true` when the contents were copied into the app's own storage because
    /// the item could not be referenced in place. `path` then points inside the
    /// sandbox and needs no security-scoped access at all.
    var isImported: Bool

    init(id: UUID = UUID(),
         kind: Kind,
         bookmark: Data?,
         path: String,
         displayName: String,
         isImported: Bool = false) {
        self.id = id
        self.kind = kind
        self.bookmark = bookmark
        self.path = path
        self.displayName = displayName
        self.isImported = isImported
    }

    var isFolder: Bool { kind == .folder }

    var symbol: String { isFolder ? "folder" : "doc" }

}

/// A batch of picked items, wrapped so it can drive a SwiftUI `sheet(item:)`.
struct StagedSelection: Identifiable {
    let id = UUID()
    let sources: [UploadSource]
}

/// What to do when the destination already holds a *different* file at the
/// same path. Files whose content is byte-identical are always skipped —
/// that is a no-op, not a conflict.
enum ConflictPolicy: String, Codable, CaseIterable, Identifiable {

    /// Overwrite the remote file with the local one (Git's normal behaviour).
    case replace
    /// Leave the remote file untouched and do not upload the local one.
    case skip
    /// Upload the local file next to the remote one under a free name.
    case rename

    var id: String { rawValue }

    var titleKey: String { "conflict.policy." + rawValue }

    var symbol: String {
        switch self {
        case .replace: return "arrow.triangle.2.circlepath"
        case .skip: return "arrow.turn.down.right"
        case .rename: return "character.cursor.ibeam"
        }
    }
}

enum ConflictNaming {

    /// Returns a path that does not collide with anything in `taken`, by
    /// inserting " (n)" before the extension: `notes.txt` → `notes (2).txt`.
    static func freePath(for path: String, taken: Set<String>) -> String {
        guard taken.contains(path) else { return path }

        let nsPath = path as NSString
        let ext = nsPath.pathExtension
        let base = nsPath.deletingPathExtension

        var counter = 2
        while counter < 1_000 {
            let candidate = ext.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(ext)"
            if !taken.contains(candidate) { return candidate }
            counter += 1
        }
        return ext.isEmpty
            ? "\(base) (\(UUID().uuidString.prefix(6)))"
            : "\(base) (\(UUID().uuidString.prefix(6))).\(ext)"
    }
}
